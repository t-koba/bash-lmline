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
[[ -n "$data" ]] && cp "$data" "$bodies/body-$count.json" || : >"$bodies/body-$count.json"
printf '%s\n' "$url" >"$bodies/url-$count.txt"
[[ -n "$header" && -r "$header" ]] && cp "$header" "$bodies/header-$count.txt" || : >"$bodies/header-$count.txt"
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == plan-catalog && "$count" == 1 ]]; then
  # The account catalog of the plan route. The engine reads the catalog from
  # the output of the command, so this request has no output file of its own
  # and no status line. The answers that follow are the provider request.
  if [[ -n "$out" ]]; then
    cat >"$out" <<'JSON'
{"data":[{"id":"gpt-plan-catalog"}]}
JSON
    printf '200\tapplication/json'
  else
    printf '%s\n' '{"data":[{"id":"gpt-plan-catalog"}]}'
  fi
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == tool-text ]]; then
  # A text tool request: on a paid route it would be another provider
  # request, and therefore another spend of the plan.
  cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"TOOL command_exists commands=ls"}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
  printf '200\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == tool-single-quote ]]; then
  # A backslash is a literal character inside a single-quoted string, so the
  # request after it is a request.
  cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"echo 'a\\'; TOOL files query=x"}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
  printf '200\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == plan-429 ]]; then
  cat >"$out" <<'JSON'
{"error":{"code":"subscription_sharing_usage_limit_exceeded","param":"","message":"usage limit reached"}}
JSON
  printf '429\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == plan-numeric-code ]]; then
  # A gateway answers with a numeric code.
  cat >"$out" <<'JSON'
{"error":{"code":401,"message":"the sign-in is not valid"}}
JSON
  printf '401\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == plan-401 ]]; then
  # The provider's own shape has no param field.
  cat >"$out" <<'JSON'
{"error":{"code":"subscription_sharing_invalid_user","message":"the sign-in is not valid"}}
JSON
  printf '401\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == tool-escaped ]]; then
  # A command whose quoted string holds an escaped quote stays a command.
  cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"echo \"a\\\"; TOOL files query=x\""}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
  printf '200\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == tool-quoted ]]; then
  # A command that mentions the protocol inside a string is a command.
  cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"echo \"see; TOOL files query=x\""}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
  printf '200\tapplication/json'
  exit 0
fi
if [[ "${LMLINE_FAKE_CURL_MODE:-}" == tool-inline ]]; then
  # The text protocol accepts a tool request appended to a sentence.
  cat >"$out" <<'JSON'
{"id":"resp_1","object":"response","model":"test-model","status":"completed",
 "output":[{"type":"message","id":"msg_1","role":"assistant",
  "content":[{"type":"output_text","text":"echo hi; TOOL command_exists commands=ls"}]}],
 "usage":{"input_tokens":3,"output_tokens":4,"total_tokens":7}}
JSON
  printf '200\tapplication/json'
  exit 0
fi
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
  case "$1" in
    *override-client.js) printf 'override-subscription-token\n' ;;
    *) printf 'test-subscription-token\n' ;;
  esac
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

# The client override reaches the engine as well: the token comes from the
# client that the route resolves.
reset_fake
printf '// the client of the override\n' >"$route_tmp/override-client.js"
if ! run_engine LMLINE_CHATGPT_CLIENT="$route_tmp/override-client.js" \
    >"$route_tmp/override.out" 2>"$route_tmp/override.err"; then
  fail "the subscription route refused the client override: $(sed -n '1p' "$route_tmp/override.err")"
fi
override_header=$(cat "$bodies_dir/header-1.txt")
[[ "$override_header" == "Authorization: Bearer override-subscription-token" ]] \
  || fail "the engine ignores the client override: $override_header"
ok "the subscription route uses the client override"

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
grep -q 'only the OpenAI API and a loopback proxy are allowed' "$route_tmp/host.err" || fail "subscription route host rejection message"
ok "subscription route keeps the plan token on the OpenAI host"

# The account catalog is read with the same plan token, so a catalog URL on
# a host the route does not allow is refused before the token is fetched,
# and no request is made.
reset_fake
if run_engine LMLINE_MODEL= LMLINE_MODELS_URL=https://foreign.example.invalid/v1/models \
    >"$route_tmp/catalog.out" 2>"$route_tmp/catalog.err"; then
  fail "subscription route accepted a foreign catalog host"
fi
[[ "$(cat "$count_file")" == 0 ]] || fail "subscription route contacted a foreign catalog host"
grep -q 'the ChatGPT subscription token is not sent to' "$route_tmp/catalog.err" \
  || fail "the refused catalog host has no reason: $(sed -n '1p' "$route_tmp/catalog.err")"
ok "subscription route refuses a foreign catalog host"

# The account catalog of the plan route is read on a host the route allows,
# with the plan token, and the run continues with the model it names.
reset_fake
out=$(run_engine LMLINE_MODEL= LMLINE_MODELS_URL=https://api.openai.com/v1/models \
    LMLINE_FAKE_CURL_MODE=plan-catalog 2>"$route_tmp/discovery.err") \
  || fail "the plan route did not read the account catalog: $(sed -n '1p' "$route_tmp/discovery.err")"
[[ "$(cat "$count_file")" == 2 ]] || fail "the plan route request count: $(cat "$count_file")"
[[ "$(cat "$bodies_dir/url-1.txt")" == "https://api.openai.com/v1/models" ]] \
  || fail "the catalog request path: $(cat "$bodies_dir/url-1.txt")"
[[ "$(cat "$bodies_dir/header-1.txt")" == "Authorization: Bearer test-subscription-token" ]] \
  || fail "the catalog credential: $(cat "$bodies_dir/header-1.txt")"
[[ "$(jq -r .model "$bodies_dir/body-2.json")" == gpt-plan-catalog ]] \
  || fail "the plan route model after the discovery: $(jq -r .model "$bodies_dir/body-2.json" 2>/dev/null)"
[[ "$(candidates_of <<<"$out")" == "echo hello" ]] || fail "the plan route candidate after the discovery"
ok "the plan route reads the account catalog on an allowed host"

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

# A cleartext base to the OpenAI host would send the plan token unprotected.
reset_fake
if run_engine LMLINE_BASE_URL="http://api.openai.com/v1" \
    >"$route_tmp/cleartext.out" 2>"$route_tmp/cleartext.err"; then
  fail "subscription route accepted a cleartext base"
fi
[[ "$(cat "$count_file")" == 0 ]] || fail "subscription route sent a cleartext request"
grep -q 'needs https' "$route_tmp/cleartext.err" || fail "subscription route cleartext message"
ok "subscription route refuses a cleartext base"

# A base without an explicit scheme would let the transport be guessed.
reset_fake
if run_engine LMLINE_BASE_URL="api.openai.com/v1" \
    >"$route_tmp/scheme.out" 2>"$route_tmp/scheme.err"; then
  fail "subscription route accepted a base without a scheme"
fi
[[ "$(cat "$count_file")" == 0 ]] || fail "subscription route sent a request without a scheme"
grep -q 'without an explicit scheme' "$route_tmp/scheme.err" || fail "subscription route scheme message"
ok "subscription route refuses a base without a scheme"

# A text tool request would be another provider request, so the paid route
# answers once and stops.
reset_fake
run_engine LMLINE_FAKE_CURL_MODE=tool-text >"$route_tmp/tool-text.out" 2>"$route_tmp/tool-text.err" || true
[[ "$(cat "$count_file")" == 1 ]] || fail "the paid route repeated the request for a text tool request"
grep -q 'does not run local tools' "$route_tmp/tool-text.err" \
  || fail "the paid route reports a tool request as a missing command: $(sed -n '1p' "$route_tmp/tool-text.err")"
ok "the subscription route makes one provider request per exchange"

# The tool request appended to a sentence is a tool request too, and it is
# reported as one.
reset_fake
run_engine LMLINE_FAKE_CURL_MODE=tool-inline >"$route_tmp/tool-inline.out" 2>"$route_tmp/tool-inline.err" || true
[[ "$(cat "$count_file")" == 1 ]] || fail "the paid route repeated the request for an inline tool request"
grep -q 'does not run local tools' "$route_tmp/tool-inline.err" \
  || fail "the paid route reports an inline tool request as a missing command: $(sed -n '1p' "$route_tmp/tool-inline.err")"
ok "the subscription route reports an inline tool request as a tool request"

# A command that mentions the protocol inside a string stays a command.
reset_fake
if ! run_engine LMLINE_FAKE_CURL_MODE=tool-quoted >"$route_tmp/tool-quoted.out" 2>"$route_tmp/tool-quoted.err"; then
  fail "the paid route dropped a command that mentions the tool protocol: $(sed -n '1p' "$route_tmp/tool-quoted.err")"
fi
quoted_candidate=$(candidates_of <"$route_tmp/tool-quoted.out")
[[ "$quoted_candidate" == 'echo "see; TOOL files query=x"' ]] \
  || fail "the paid route dropped a command that mentions the tool protocol: $quoted_candidate"
ok "the subscription route keeps a command that mentions the tool protocol"

# A command whose quoted string holds an escaped quote stays a command too.
reset_fake
if ! run_engine LMLINE_FAKE_CURL_MODE=tool-escaped >"$route_tmp/tool-escaped.out" 2>"$route_tmp/tool-escaped.err"; then
  fail "the paid route dropped a command with an escaped quote: $(sed -n '1p' "$route_tmp/tool-escaped.err")"
fi
escaped_candidate=$(candidates_of <"$route_tmp/tool-escaped.out")
[[ "$escaped_candidate" == 'echo "a\"; TOOL files query=x"' ]] \
  || fail "the paid route dropped a command with an escaped quote: $escaped_candidate"
ok "the subscription route keeps a command with an escaped quote"

# A plan refusal is reported with the plan recovery, not with the API-key
# advice, and the provider code stays visible.
reset_fake
if run_engine LMLINE_FAKE_CURL_MODE=plan-429 >"$route_tmp/plan-429.out" 2>"$route_tmp/plan-429.err"; then
  fail "the paid route accepted a plan refusal"
fi
grep -q 'subscription_sharing_usage_limit_exceeded' "$route_tmp/plan-429.err" \
  || fail "the plan error code is lost: $(sed -n '1p' "$route_tmp/plan-429.err")"
grep -q 'chatgpt.com/settings/usage' "$route_tmp/plan-429.err" \
  || fail "the plan usage limit has no recovery: $(sed -n '1p' "$route_tmp/plan-429.err")"
! grep -q 'set-secret' "$route_tmp/plan-429.err" || fail "the plan route gives API-key advice"
! grep -q 'LMLINE_HTTP_RETRIES' "$route_tmp/plan-429.err" || fail "the plan route advises raising the retries"
reset_fake
if run_engine LMLINE_FAKE_CURL_MODE=plan-401 >"$route_tmp/plan-401.out" 2>"$route_tmp/plan-401.err"; then
  fail "the paid route accepted a refused sign-in"
fi
grep -q 'lmline chatgpt login' "$route_tmp/plan-401.err" \
  || fail "the refused plan sign-in has no recovery: $(sed -n '1p' "$route_tmp/plan-401.err")"
! grep -q 'set-secret' "$route_tmp/plan-401.err" || fail "the plan route gives API-key advice"
grep -q 'the sign-in is not valid' "$route_tmp/plan-401.err" \
  || fail "the provider message is lost: $(sed -n '1p' "$route_tmp/plan-401.err")"
! grep -q '{"error"' "$route_tmp/plan-401.err" || fail "the raw provider body is shown instead of the message"
ok "the plan route reports its own recovery"

# A provider that answers with a numeric code keeps its message.
reset_fake
if run_engine LMLINE_FAKE_CURL_MODE=plan-numeric-code >"$route_tmp/plan-numeric.out" 2>"$route_tmp/plan-numeric.err"; then
  fail "the paid route accepted a refused sign-in"
fi
grep -q 'the sign-in is not valid' "$route_tmp/plan-numeric.err" \
  || fail "the provider message is lost for a numeric code: $(sed -n '1p' "$route_tmp/plan-numeric.err")"
! grep -q '{"error"' "$route_tmp/plan-numeric.err" || fail "the raw provider body is shown instead of the message"
ok "the plan route keeps the message of a numeric error code"

# A request after a single-quoted string that ends in a backslash is a
# request, because the backslash is a literal character there.
reset_fake
run_engine LMLINE_FAKE_CURL_MODE=tool-single-quote >"$route_tmp/tool-single-quote.out" 2>"$route_tmp/tool-single-quote.err" || true
grep -q 'does not run local tools' "$route_tmp/tool-single-quote.err" \
  || fail "a request after a single-quoted string is not recognized: $(sed -n '1p' "$route_tmp/tool-single-quote.err")"
ok "the subscription route recognizes a request after a single-quoted string"

ok "chatgpt route"
