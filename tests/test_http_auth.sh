#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: every API-key request path must refuse plaintext credentials before curl.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-http-auth-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export LMLINE_CONFIG_DIR="$tmp/config" LMLINE_API_KEY_FILE="$tmp/key"
export LMLINE_AUTH_MODE=api-key LMLINE_AUTH_HEADER=X-Test-Key LMLINE_AUTH_SCHEME=
export LMLINE_TOOL_MODE=none LMLINE_MODEL=test-model
export LMLINE_FAKE_HTTP_LOG="$tmp/requests"
mkdir -p "$tmp/bin"
export PATH="$tmp/bin:$PATH"
printf '# list files\n' >"$tmp/line"
printf '## available_tools\n' >"$tmp/context"
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
    http://*|https://*) url=$1; shift ;;
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
"$cli" endpoint add catalog https://api.test.invalid/v1 --auth-header X-Test-Key --auth-scheme ''
canary=SYNTHETIC-HTTP-AUTH-TEST
printf '%s\n' "$canary" | "$cli" endpoint set-secret catalog >/dev/null 2>&1

run_route() {
  case "$route" in
    generate) "$repo_dir/lmline/engine" "${engine_args[@]}" ;;
    discover) LMLINE_MODEL= "$repo_dir/lmline/engine" "${engine_args[@]}" ;;
    refresh) "$cli" model refresh catalog ;;
    doctor) "$cli" doctor --check-api ;;
    boundary)
      # Exercise the shell-local setting allowlist, not just exported env.
      bash -p -c '
        source "$1"; shift
        LMLINE_ALLOW_INSECURE_HTTP_AUTH=1
        export -n LMLINE_ALLOW_INSECURE_HTTP_AUTH
        __lmline_validation_run entry "$@"
      ' _ "$repo_dir/lmline/validation-boundary.bash" "$repo_dir/lmline/engine" "${engine_args[@]}"
      ;;
  esac
}

check_route() {
  local expectation=$1 expected_auth=$2 count=1 status=0
  : >"$tmp/requests"
  run_route >"$tmp/output" 2>&1 || status=$?
  ! grep -Fq "$canary" "$tmp/output" "$tmp/requests" || fail "$route: credential in diagnostics"
  if [[ "$expectation" == deny ]]; then
    [[ "$status" != 0 && ! -s "$tmp/requests" ]] || fail "$route: plaintext request was not blocked"
    grep -q 'refusing.*plaintext HTTP.*LMLINE_ALLOW_INSECURE_HTTP_AUTH=1' "$tmp/output" || fail "$route: missing safe guidance"
  else
    [[ "$status" == 0 ]] || fail "$route: permitted request failed"
    [[ "$route" != discover ]] || count=2
    [[ $(wc -l <"$tmp/requests") -eq "$count" ]] || fail "$route: request count"
    ! grep -v " $expected_auth\$" "$tmp/requests" || fail "$route: wrong auth header presence"
    case "$route" in
      generate|discover|boundary) grep -q 'echo secured' "$tmp/output" || fail "$route: candidate missing" ;;
      doctor) grep -q 'connection=ok' "$tmp/output" || fail 'doctor: probe failed' ;;
      refresh) "$cli" model list catalog | grep -q test-model || fail 'refresh: model missing' ;;
    esac
  fi
}

for route in generate discover refresh doctor; do
  for scenario in deny opt-in https empty; do
    export LMLINE_BASE_URL=https://api.test.invalid/v1
    export LMLINE_MODELS_URL=http://catalog.test.invalid/models
    unset LMLINE_ALLOW_INSECURE_HTTP_AUTH
    printf '%s\n' "$canary" >"$LMLINE_API_KEY_FILE"
    # Inference checks its base; the other paths check an alternate catalog.
    [[ "$route" != generate ]] || export LMLINE_BASE_URL=http://api.test.invalid/v1
    case "$scenario" in
      opt-in) export LMLINE_ALLOW_INSECURE_HTTP_AUTH=1 ;;
      https) export LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODELS_URL=https://catalog.test.invalid/models ;;
      empty) : >"$LMLINE_API_KEY_FILE" ;;
    esac
    if [[ "$route" == refresh ]]; then
      "$cli" endpoint add catalog "$LMLINE_BASE_URL" --models-url "$LMLINE_MODELS_URL"
      cp "$LMLINE_API_KEY_FILE" "$LMLINE_CONFIG_DIR/secrets/endpoint-catalog-api-key.secret"
    fi
    case "$scenario" in
      deny) check_route deny 1 ;;
      empty) check_route allow 0 ;;
      *) check_route allow 1 ;;
    esac
  done
done

route=generate
export LMLINE_BASE_URL=http://api.test.invalid/v1
printf '%s\n' "$canary" >"$LMLINE_API_KEY_FILE"
for value in '' 0 true 01 2; do
  export LMLINE_ALLOW_INSECURE_HTTP_AUTH=$value
  check_route deny 1
done
# No key file remains compatible with anonymous HTTP too.
LMLINE_API_KEY_FILE= check_route allow 0
route=boundary
check_route allow 1
ok 'API-key HTTP transport policy covers inference, discovery, refresh, and doctor'
