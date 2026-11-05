#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: every API-key request path must refuse plaintext context and credentials before curl.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-http-auth-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export LMLINE_CONFIG_DIR="$tmp/config" LMLINE_API_KEY_FILE="$tmp/key"
export LMLINE_AUTH_MODE=api-key LMLINE_AUTH_HEADER=X-Test-Key LMLINE_AUTH_SCHEME=
export LMLINE_TOOL_MODE=none LMLINE_MODEL=test-model
export LMLINE_FAKE_HTTP_LOG="$tmp/requests"
mkdir -p "$tmp/bin"
export PATH="$tmp/bin:$PATH"
printf '# list files\n' >"$tmp/line"
context_canary=SYNTHETIC-HTTP-CONTEXT-TEST
printf '## available_tools\n%s\n' "$context_canary" >"$tmp/context"
engine_args=(--mode generate --shell bash --cwd "$tmp" --point 0 --line-file "$tmp/line" --context-file "$tmp/context" --n 1)

# Never record header contents, only whether an auth header would be sent.
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
[[ "$1" != --version ]] || { printf 'curl test\n'; exit 0; }
out= url= auth=0
while (($#)); do
  case "$1" in
    -H) [[ "$2" != @* ]] || auth=1; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w|--max-time|--data-binary) shift 2 ;;
    [hH][tT][tT][pP]://*|[hH][tT][tT][pP][sS]://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$url" "$auth" >>"${LMLINE_FAKE_HTTP_LOG:?}"
if [[ "$out" == /dev/null ]]; then
  printf '200'
elif [[ -n "$out" ]]; then
  printf '%s\n' '{"choices":[{"message":{"role":"assistant","content":"echo secured"},"finish_reason":"stop"}]}' >"$out"
  printf '200\tapplication/json'
else
  printf '%s\n' '{"data":[{"id":"test-model"}]}'
fi
CURL
chmod +x "$tmp/bin/curl"

cli="$repo_dir/lmline/lmline"
canary=SYNTHETIC-HTTP-AUTH-TEST

run_route() {
  case "$route" in
    generate) "$repo_dir/lmline/engine" "${engine_args[@]}" ;;
    discover) LMLINE_MODEL= "$repo_dir/lmline/engine" "${engine_args[@]}" ;;
    refresh) "$cli" model refresh "$endpoint" ;;
    doctor) "$cli" doctor --check-api ;;
    boundary)
      # Exercise the shell-local setting allowlist, not just exported env.
      bash -p -c '
        source "$1"; shift
        LMLINE_ALLOW_INSECURE_HTTP=1
        export -n LMLINE_ALLOW_INSECURE_HTTP
        __lmline_validation_run entry "$@"
      ' _ "$repo_dir/lmline/validation-boundary.bash" "$repo_dir/lmline/engine" "${engine_args[@]}"
      ;;
  esac
}

check_route() {
  local expectation=$1 expected_auth=$2 count=1 status=0
  : >"$tmp/requests"
  run_route >"$tmp/output" 2>&1 || status=$?
  ! grep -Fq -e "$canary" -e "$context_canary" "$tmp/output" "$tmp/requests" || fail "$route: credential or context in diagnostics"
  if [[ "$expectation" == deny || "$expectation" == invalid ]]; then
    [[ "$status" != 0 && ! -s "$tmp/requests" ]] || fail "$route: unsafe request was not blocked"
    if [[ "$expectation" == invalid ]]; then
      grep -q 'refusing destination: an explicit https://' "$tmp/output" || fail "$route: missing scheme guidance"
      ! grep -Fq -e "$LMLINE_BASE_URL" -e "$LMLINE_MODELS_URL" "$tmp/output" || fail "$route: URL in diagnostics"
    else
      grep -q 'refusing.*plaintext HTTP.*LMLINE_ALLOW_INSECURE_HTTP=1' "$tmp/output" || fail "$route: missing safe guidance"
    fi
  else
    [[ "$status" == 0 ]] || fail "$route: permitted request failed"
    [[ "$route" != discover ]] || count=2
    [[ $(wc -l <"$tmp/requests") -eq "$count" ]] || fail "$route: request count"
    ! grep -v " $expected_auth\$" "$tmp/requests" || fail "$route: wrong auth header presence"
    case "$route" in
      generate|discover|boundary) grep -q 'echo secured' "$tmp/output" || fail "$route: candidate missing" ;;
      doctor) grep -q 'connection=ok' "$tmp/output" || fail 'doctor: probe failed' ;;
      refresh) "$cli" model list "$endpoint" | grep -q test-model || fail 'refresh: model missing' ;;
    esac
  fi
}

for route in generate discover refresh doctor; do
  for key in keyed empty absent; do
    for scenario in deny opt-in https; do
      export LMLINE_BASE_URL=https://api.test.invalid/v1
      export LMLINE_MODELS_URL=http://catalog.test.invalid/models
      unset LMLINE_ALLOW_INSECURE_HTTP
      export LMLINE_API_KEY_FILE="$tmp/key"
      printf '%s\n' "$canary" >"$LMLINE_API_KEY_FILE"
      expected_auth=1
      case "$key" in
        empty) : >"$LMLINE_API_KEY_FILE"; expected_auth=0 ;;
        absent) export LMLINE_API_KEY_FILE=; expected_auth=0 ;;
      esac
      # Inference checks its base; the other paths check an alternate catalog.
      [[ "$route" != generate ]] || export LMLINE_BASE_URL=http://api.test.invalid/v1
      case "$scenario" in
        opt-in) export LMLINE_ALLOW_INSECURE_HTTP=1 ;;
        https) export LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODELS_URL=https://catalog.test.invalid/models ;;
      esac
      if [[ "$route" == refresh ]]; then
        endpoint=catalog-$key
        "$cli" endpoint add "$endpoint" "$LMLINE_BASE_URL" --models-url "$LMLINE_MODELS_URL" --auth-header X-Test-Key --auth-scheme ''
        if [[ "$key" != absent ]]; then
          printf '%s\n' "$canary" | "$cli" endpoint set-secret "$endpoint" >/dev/null 2>&1
          cp "$LMLINE_API_KEY_FILE" "$LMLINE_CONFIG_DIR/secrets/endpoint-$endpoint-api-key.secret"
        fi
      fi
      case "$scenario" in
        deny) check_route deny "$expected_auth" ;;
        *) check_route allow "$expected_auth" ;;
      esac
    done
  done
done

# Actual engine paths must reject curl's implicit HTTP and other protocols,
# even with the HTTP opt-in; check both inference and catalog discovery.
export LMLINE_ALLOW_INSECURE_HTTP=1 LMLINE_API_KEY_FILE="$tmp/key"
printf '%s\n' "$canary" >"$LMLINE_API_KEY_FILE"
for route in generate discover; do
  for destination in '127.0.0.1:9/v1' 'ftp://api.test.invalid/v1'; do
    export LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODELS_URL=https://catalog.test.invalid/models
    if [[ "$route" == generate ]]; then
      export LMLINE_BASE_URL=$destination
    else
      export LMLINE_MODELS_URL=$destination
    fi
    check_route invalid 0
  done
done

# The unused catalog is empty in inference; mixed-case HTTPS must still pass.
route=generate
export LMLINE_BASE_URL=hTtPs://api.test.invalid/v1
unset LMLINE_ALLOW_INSECURE_HTTP
check_route allow 1
export LMLINE_BASE_URL=http://api.test.invalid/v1
for key in keyed empty absent; do
  export LMLINE_API_KEY_FILE="$tmp/key"
  printf '%s\n' "$canary" >"$LMLINE_API_KEY_FILE"
  case "$key" in
    empty) : >"$LMLINE_API_KEY_FILE" ;;
    absent) export LMLINE_API_KEY_FILE= ;;
  esac
  for value in '' 0 true 01 2; do
    export LMLINE_ALLOW_INSECURE_HTTP=$value
    check_route deny 0
  done
done
route=boundary
export LMLINE_API_KEY_FILE="$tmp/key"
printf '%s\n' "$canary" >"$LMLINE_API_KEY_FILE"
check_route allow 1
ok 'API-key HTTP transport policy protects context and credentials across inference, discovery, refresh, and doctor'
