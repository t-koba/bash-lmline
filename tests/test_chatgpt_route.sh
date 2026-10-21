#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the ChatGPT subscription route sends the plan token to the OpenAI Responses API with the documented request contract and never falls back to a metered API key.

route_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-chatgpt-route-test.XXXXXX")
trap 'rm -rf "$route_tmp"' EXIT

fake_bin="$route_tmp/fake-bin"
bodies_dir="$route_tmp/bodies"
count_file="$route_tmp/curl-count"
mkdir -p "$fake_bin" "$bodies_dir"

# The fake provider records the request body, the request URL and the
# authentication header, then answers with a Responses body.
cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
out=; data=; url=; header=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    -H)
      case "$2" in
        @*) header=${2#@} ;;
      esac
      shift 2
      ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_COUNT:?}
bodies=${LMLINE_FAKE_CURL_BODIES:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
cp "$data" "$bodies/body-$count.json"
printf '%s\n' "$url" >"$bodies/url-$count.txt"
[[ -n "$header" && -r "$header" ]] && cp "$header" "$bodies/header-$count.txt" || : >"$bodies/header-$count.txt"
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == invalid ]]; then
  # A candidate with broken shell syntax: the engine rejects it locally and
  # would ask the provider for a second answer.
  cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"echo \"unclosed"}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
  printf '200\tapplication/json'
  exit 0
fi
cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"echo hello"}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
printf '200\tapplication/json'
CURL
chmod +x "$fake_bin/curl"

# The subscription token comes from a fake client, so the test stays offline
# and never uses a real credential.
cat >"$fake_bin/node" <<'NODE'
#!/usr/bin/env bash
if [[ "${2-}" == token ]]; then
  printf 'test-subscription-token\n'
  exit 0
fi
exit 1
NODE
chmod +x "$fake_bin/node"

printf '# list files\n' >"$route_tmp/line"
printf '## available_tools\n' >"$route_tmp/context"
printf 'metered-api-key-sentinel\n' >"$route_tmp/api-key"

reset_fake() {
  rm -f "$bodies_dir"/body-*.json "$bodies_dir"/url-*.txt "$bodies_dir"/header-*.txt
  printf '0\n' >"$count_file"
}

# Runs the engine on the subscription route. The extra arguments are
# environment assignments and come last, so a case can override the defaults.
run_engine() {
  env PATH="$fake_bin:$PATH" \
    LMLINE_FAKE_CURL_COUNT="$count_file" \
    LMLINE_FAKE_CURL_BODIES="$bodies_dir" \
    LMLINE_CONFIG_DIR="$route_tmp/config" \
    LMLINE_BASE_URL=https://api.openai.com/v1 \
    LMLINE_MODEL=test-model \
    LMLINE_API_KEY_FILE="$route_tmp/api-key" \
    LMLINE_AUTH_MODE=chatgpt \
    "$@" \
    "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" \
    --point 0 --line-file "$route_tmp/line" --context-file "$route_tmp/context" \
    --n 1
}

# The subscription token is sent as a Bearer credential to the OpenAI
# Responses API, and the metered API key is never used.
reset_fake
out=$(run_engine 2>"$route_tmp/engine.err") || fail "subscription route request failed: $(sed -n '1p' "$route_tmp/engine.err")"
[[ "$(candidates_of <<<"$out")" == "echo hello" ]] || fail "subscription route candidate"
[[ "$(cat "$count_file")" == 1 ]] || fail "subscription route request count"
[[ "$(cat "$bodies_dir/url-1.txt")" == "https://api.openai.com/v1/responses" ]] || fail "subscription route request path"
header=$(cat "$bodies_dir/header-1.txt")
[[ "$header" == "Authorization: Bearer test-subscription-token" ]] || fail "subscription route credential: $header"
! grep -q 'metered-api-key-sentinel' "$bodies_dir/header-1.txt" || fail "subscription route sent the API key"
ok "subscription route sends the plan token to the Responses API"

# The request follows the documented contract of the plan route.
payload=$(cat "$bodies_dir/body-1.json")
jq -e '.store == false' <<<"$payload" >/dev/null || fail "subscription route store"
jq -e '.stream == true' <<<"$payload" >/dev/null || fail "subscription route stream"
jq -e '(.instructions | type) == "string" and (.instructions | length) > 0' <<<"$payload" >/dev/null || fail "subscription route instructions"
jq -e '[.input[]? | select(.role == "system")] | length == 0' <<<"$payload" >/dev/null || fail "subscription route system item"
for field in temperature max_output_tokens top_p user metadata background conversation previous_response_id; do
  jq -e --arg field "$field" 'has($field) | not' <<<"$payload" >/dev/null || fail "subscription route carries $field"
done
jq -e 'has("tools") | not' <<<"$payload" >/dev/null || fail "subscription route carries function tools"
ok "subscription route request contract"

# The plan token never travels to another host.
reset_fake
if run_engine LMLINE_BASE_URL=https://api.example.invalid/v1 >"$route_tmp/host.out" 2>"$route_tmp/host.err"; then
  fail "subscription route accepted a non-OpenAI host"
fi
[[ "$(cat "$count_file")" == 0 ]] || fail "subscription route contacted a non-OpenAI host"
grep -q 'only sent to the OpenAI API' "$route_tmp/host.err" || fail "subscription route host rejection message"
ok "subscription route keeps the plan token on the OpenAI host"

# The route requires the Responses API format.
reset_fake
if run_engine LMLINE_API_FORMAT=chat >"$route_tmp/format.out" 2>"$route_tmp/format.err"; then
  fail "subscription route accepted a non-responses format"
fi
grep -q 'LMLINE_API_FORMAT=responses' "$route_tmp/format.err" || fail "subscription route format message"
ok "subscription route requires the responses format"

# A failing subscription sign-in never falls back to the metered API key.
reset_fake
cat >"$fake_bin/node" <<'NODE'
#!/usr/bin/env bash
printf 'lmline-chatgpt: no signed-in session\n' >&2
exit 1
NODE
chmod +x "$fake_bin/node"
if run_engine >"$route_tmp/auth.out" 2>"$route_tmp/auth.err"; then
  fail "subscription route continued without a session"
fi
[[ "$(cat "$count_file")" == 0 ]] || fail "subscription route sent a request without a session"
grep -q 'ChatGPT subscription auth failed' "$route_tmp/auth.err" || fail "subscription route auth message"
! grep -q 'metered-api-key-sentinel' "$route_tmp/auth.err" || fail "subscription route leaked the API key"
ok "subscription route fails closed without a session"

# The fake subscription client is installed again: the case above replaced it
# with a failing stub.
cat >"$fake_bin/node" <<'NODE'
#!/usr/bin/env bash
if [[ "${2-}" == token ]]; then
  printf 'test-subscription-token\n'
  exit 0
fi
exit 1
NODE
chmod +x "$fake_bin/node"

# A base URL with embedded credentials would send the plan token to a host
# the text does not name, so the route refuses it before any request.
reset_fake
if run_engine LMLINE_BASE_URL="https://api.openai.com:x@other.example.invalid/v1" \
    >"$route_tmp/creds.out" 2>"$route_tmp/creds.err"; then
  fail "subscription route accepted a base URL with embedded credentials"
fi
[[ "$(cat "$count_file")" == 0 ]] || fail "subscription route contacted a host with embedded credentials"
grep -q 'embedded credentials' "$route_tmp/creds.err" || fail "subscription route credentials message"
ok "subscription route refuses a base URL with embedded credentials"

# A loopback proxy and a port on the OpenAI host stay on the allowed list.
reset_fake
if ! run_engine LMLINE_BASE_URL="http://[::1]:8731/v1" \
    >"$route_tmp/ipv6.out" 2>"$route_tmp/ipv6.err"; then
  fail "subscription route refused a bracketed IPv6 loopback base: $(sed -n '1p' "$route_tmp/ipv6.err")"
fi
[[ "$(cat "$count_file")" == 1 ]] || fail "subscription route request count for the IPv6 loopback base"
[[ "$(cat "$bodies_dir/url-1.txt")" == "http://[::1]:8731/v1/responses" ]] || fail "subscription route IPv6 request path"
reset_fake
if ! run_engine LMLINE_BASE_URL="https://api.openai.com:8443/v1" \
    >"$route_tmp/port.out" 2>"$route_tmp/port.err"; then
  fail "subscription route refused a port on the OpenAI host: $(sed -n '1p' "$route_tmp/port.err")"
fi
[[ "$(cat "$count_file")" == 1 ]] || fail "subscription route request count for the OpenAI host with a port"
ok "subscription route accepts a loopback proxy and a port on the OpenAI host"

# A rejected answer would be asked again on an ordinary route, but a second
# request would spend the plan, so the subscription route reports instead.
reset_fake
if run_engine LMLINE_FAKE_CURL_MODE=invalid >"$route_tmp/retry.out" 2>"$route_tmp/retry.err"; then
  fail "subscription route accepted a rejected answer"
fi
[[ "$(cat "$count_file")" == 1 ]] || fail "subscription route repeated a rejected answer"
grep -q 'not repeated' "$route_tmp/retry.err" || fail "subscription route reports the refused repeat"
ok "subscription route does not repeat a rejected answer"

ok "chatgpt route"
