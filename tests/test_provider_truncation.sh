#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: incomplete provider responses are rejected before cache or tool dispatch across API formats.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-provider-truncation-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
fake_bin=$cfg_tmp/fake-bin
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w|-H|--max-time|-X|--data-binary) shift 2 ;;
    -q|-sS|-N) shift ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
if [[ -d "$LMLINE_FAKE_CURL_FIXTURES" && -f "$LMLINE_FAKE_CURL_FIXTURES/$count.json" ]]; then
  cp "$LMLINE_FAKE_CURL_FIXTURES/$count.json" "$out"
else
  cp "$LMLINE_FAKE_CURL_FIXTURE" "$out"
fi
code=${LMLINE_FAKE_CURL_CODE:-200}
if [[ -f "$LMLINE_FAKE_CURL_FIXTURES/$count.code" ]]; then
  read -r code <"$LMLINE_FAKE_CURL_FIXTURES/$count.code"
fi
printf '%s\tapplication/json' "$code"
CURL_EOF
chmod +x "$fake_bin/curl"

case_dir=
api_format=
case_name=
init_case() {
  case_name=$1
  api_format=$2
  case_dir=$cfg_tmp/$case_name
  mkdir -p "$case_dir"
  LMLINE_CONFIG_DIR="$case_dir/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
  LMLINE_CONFIG_DIR="$case_dir/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model
  printf 'generate a harmless command for %s\n' "$case_name" >"$case_dir/line"
  printf '## available_tools\n' >"$case_dir/context"
  printf '0\n' >"$case_dir/curl-count"
  : >"$case_dir/response.json"
}

invoke_engine() {
  local tool_mode=${1:-none}
  local engine_mode=${2:-generate}
  if engine_output=$(PATH="$fake_bin:$PATH" \
    LMLINE_CONFIG_DIR="$case_dir/config" \
    LMLINE_API_FORMAT="$api_format" \
    LMLINE_TOOL_MODE="$tool_mode" \
    LMLINE_CACHE_TTL=600 \
    LMLINE_FAKE_CURL_STATE="$case_dir/curl-count" \
    LMLINE_FAKE_CURL_FIXTURE="$case_dir/response.json" \
    LMLINE_FAKE_CURL_FIXTURES="$case_dir/fixtures" \
    "$repo_dir/lmline/engine" --mode "$engine_mode" --shell bash --cwd "$repo_dir" --point 0 \
      --line-file "$case_dir/line" --context-file "$case_dir/context" --n 1 \
      2>"$case_dir/stderr"); then
    engine_status=0
  else
    engine_status=$?
  fi
}

cache_count() {
  find "$case_dir/config/cache" -type f 2>/dev/null | wc -l | tr -d ' '
}

assert_complete() {
  local label=$1
  invoke_engine
  [[ $engine_status == 0 ]] || fail "$label complete response status ($engine_status)"
  [[ "$(candidates_of <<<"$engine_output")" == 'echo provider-candidate' ]] || fail "$label complete candidate"
  [[ $(cache_count) -gt 0 ]] || fail "$label complete response cached"
}

assert_truncated() {
  local label=$1 status=$2 guidance=${3:-LMLINE_MAX_TOKENS}
  invoke_engine
  [[ $engine_status != 0 ]] || fail "$label truncated response unexpectedly succeeded"
  [[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "$label emitted candidate after truncation"
  [[ $(cache_count) == 0 ]] || fail "$label cached a truncated response"
  grep -Fq "incomplete command response ($status)" "$case_dir/stderr" || fail "$label safe truncation diagnostic"
  grep -Fq "$guidance" "$case_dir/stderr" || fail "$label actionable diagnostic"
  ! grep -Fq 'provider-candidate' "$case_dir/stderr" || fail "$label diagnostic leaked response content"
}

# Complete and truncated response fixtures exercise the shared acceptance
# boundary after each provider format has normalized its status.
init_case chat-complete chat
cat >"$case_dir/response.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo provider-candidate"},"finish_reason":"stop"}]}
JSON
assert_complete chat

init_case chat-truncated chat
cat >"$case_dir/response.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo provider-candidate"},"finish_reason":"LeNgTh"}]}
JSON
assert_truncated chat length

init_case messages-complete messages
cat >"$case_dir/response.json" <<'JSON'
{"content":[{"type":"text","text":"echo provider-candidate"}],"stop_reason":"end_turn"}
JSON
assert_complete messages

init_case messages-truncated messages
cat >"$case_dir/response.json" <<'JSON'
{"content":[{"type":"text","text":"echo provider-candidate"}],"stop_reason":"max_tokens"}
JSON
assert_truncated messages max_tokens

init_case messages-context-window messages
cat >"$case_dir/response.json" <<'JSON'
{"content":[{"type":"text","text":"echo provider-candidate"}],"stop_reason":"model_context_window_exceeded"}
JSON
assert_truncated messages model_context_window_exceeded 'shorten the prompt/context'

init_case responses-complete responses
cat >"$case_dir/response.json" <<'JSON'
{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"echo provider-candidate"}]}]}
JSON
assert_complete responses

init_case responses-truncated responses
cat >"$case_dir/response.json" <<'JSON'
{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"echo provider-candidate"}]}]}
JSON
assert_truncated responses 'incomplete: max_output_tokens'

# jq accepts multiple documents; a later completed response must not mask an
# incomplete first response and admit its command text.
init_case responses-multiple-documents responses
jq '.output[0].content[0].text = "echo FROM_INCOMPLETE"' \
  "$cfg_tmp/responses-truncated/response.json" >"$case_dir/response.json"
cat "$cfg_tmp/responses-complete/response.json" >>"$case_dir/response.json"
invoke_engine
[[ $engine_status != 0 ]] || fail "multiple response documents unexpectedly succeeded"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "multiple response documents emitted candidate"
[[ $(cache_count) == 0 ]] || fail "multiple response documents cached"
grep -Fq 'expected exactly one JSON object' "$case_dir/stderr" || fail "multiple response documents diagnostic"

# Provider-controlled reasons are rendered safely without changing the raw
# equality check for the stream-ended recovery diagnostic.
for reason in max_output_tokens stream_ended_without_completion; do
  init_case "responses-control-$reason" responses
  jq --arg reason "$reason" '.incomplete_details.reason = ("\u001b[2J" + $reason)' \
    "$cfg_tmp/responses-truncated/response.json" >"$case_dir/response.json"
  assert_truncated "responses control $reason" "incomplete: $reason"
  ! LC_ALL=C grep -q '[[:cntrl:]]' "$case_dir/stderr" || fail "responses reason emitted terminal controls"
done

# A provider reason containing LF must stay a single diagnostic line: the raw
# value still drives the exact stream-ended comparison, but the sanitized
# display value is flattened after safe rendering.
init_case responses-reason-newline responses
jq --arg reason $'max_output_tokens\nINJECTED: forged diagnostic' '.incomplete_details.reason = $reason' \
  "$cfg_tmp/responses-truncated/response.json" >"$case_dir/response.json"
invoke_engine
[[ $engine_status != 0 ]] || fail "responses reason newline unexpectedly succeeded"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "responses reason newline emitted candidate"
[[ $(cache_count) == 0 ]] || fail "responses reason newline cached a truncated response"
grep -Fq "incomplete command response (incomplete:" "$case_dir/stderr" || fail "responses reason newline diagnostic"
! LC_ALL=C grep -q '[[:cntrl:]]' "$case_dir/stderr" || fail "responses reason newline emitted terminal controls"
! grep -q '^INJECTED' "$case_dir/stderr" || fail "responses reason newline split diagnostic line"
# grep -c avoids BSD wc's padded scalar output in these string comparisons.
[[ $(grep -c '^' "$case_dir/stderr") == 1 ]] || fail "responses reason newline split diagnostic"
grep -Fq 'INJECTED: forged diagnostic' "$case_dir/stderr" || fail "responses reason newline lost sanitized detail"

# A JSON NUL must not be dropped by Bash before the exact recovery test.
init_case responses-reason-nul responses
cat >"$case_dir/response.json" <<'JSON'
{"status":"incomplete","incomplete_details":{"reason":"stream_ended_without_completion\u0000"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"echo provider-candidate"}]}]}
JSON
invoke_engine
[[ $engine_status != 0 ]] || fail "responses NUL reason unexpectedly succeeded"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "responses NUL reason emitted candidate"
[[ $(cache_count) == 0 ]] || fail "responses NUL reason cached a truncated response"
grep -Fq 'incomplete command response (incomplete: stream_ended_without_completion' "$case_dir/stderr" || fail "responses NUL reason generic diagnostic"
grep -Fq 'LMLINE_MAX_TOKENS' "$case_dir/stderr" || fail "responses NUL reason generic advice"
! grep -Fq 'response stream ended before completion' "$case_dir/stderr" || fail "responses NUL reason used exact recovery classification"
! grep -Fq 'ignored null byte' "$case_dir/stderr" || fail "responses NUL reason entered a Bash variable"
! LC_ALL=C grep -q '[[:cntrl:]]' "$case_dir/stderr" || fail "responses NUL reason emitted terminal controls"
[[ $(grep -c '^' "$case_dir/stderr") == 1 ]] || fail "responses NUL reason split diagnostic"

init_case responses-stream-ended responses
jq '.incomplete_details.reason = "stream_ended_without_completion"' \
  "$cfg_tmp/responses-truncated/response.json" >"$case_dir/response.json"
invoke_engine
[[ $engine_status != 0 ]] || fail "responses stream-ended unexpectedly succeeded"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "responses stream-ended emitted candidate"
[[ $(cache_count) == 0 ]] || fail "responses stream-ended cached"
grep -Fxq 'lmline-engine: the response stream ended before completion; the command response is incomplete and was not accepted' \
  "$case_dir/stderr" || fail "responses exact stream-ended recovery diagnostic"
! grep -Fq 'LMLINE_MAX_TOKENS' "$case_dir/stderr" || fail "responses stream-ended suggested an output cap"

# A failed Responses body is a provider failure in every buffered mode,
# including explain, where partial output must not be shown as an answer.
init_case responses-failed responses
cat >"$case_dir/response.json" <<'JSON'
{"status":"failed","error":{"code":"server_error","message":"boom"},"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"echo partial-candidate"}]}]}
JSON
invoke_engine none explain
[[ $engine_status != 0 ]] || fail "responses failed response unexpectedly succeeded in explain"
[[ -z "$engine_output" ]] || fail "responses failed response produced output in explain"
grep -Fq 'request failed: server_error: boom' "$case_dir/stderr" || fail "responses failed response explain diagnostic"
! grep -Fq 'partial-candidate' "$case_dir/stderr" || fail "responses failed response leaked content"
ok "responses failure rejects explain"

# Compatibility: absent/null statuses and unfamiliar provider statuses are
# not rejected by a broad success allowlist.
init_case missing-status chat
cat >"$case_dir/response.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo provider-candidate"}}]}
JSON
assert_complete missing-status

init_case null-status chat
cat >"$case_dir/response.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo provider-candidate"},"finish_reason":null}]}
JSON
assert_complete null-status

init_case unfamiliar-status messages
cat >"$case_dir/response.json" <<'JSON'
{"content":[{"type":"text","text":"echo provider-candidate"}],"stop_reason":"vendor_future_state"}
JSON
assert_complete unfamiliar-status

# A truncated initial native tool-call response is rejected before the local
# tool loop can dispatch it.
init_case truncated-tool-call chat
cat >"$case_dir/response.json" <<'JSON'
{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"command_exists","arguments":"{\"commands\":\"echo\"}"}}]}}]}
JSON
invoke_engine openai
[[ $engine_status != 0 ]] || fail "truncated tool call unexpectedly succeeded"
[[ $(cat "$case_dir/curl-count") == 1 ]] || fail "truncated tool call dispatched another round"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "truncated tool call emitted candidate"
[[ $(cache_count) == 0 ]] || fail "truncated tool call cached"

# A completed tool round followed by a truncated second response fails before
# parsing/dispatching the second response's tool call.
init_case truncated-tool-round chat
mkdir -p "$case_dir/fixtures"
cat >"$case_dir/fixtures/1.json" <<'JSON'
{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"command_exists","arguments":"{\"commands\":\"echo\"}"}}]}}]}
JSON
cat >"$case_dir/fixtures/2.json" <<'JSON'
{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"echo provider-candidate","tool_calls":[{"id":"call_2","type":"function","function":{"name":"command_exists","arguments":"{\"commands\":\"find\"}"}}]}}]}
JSON
invoke_engine openai
[[ $engine_status != 0 ]] || fail "truncated tool-round response unexpectedly succeeded"
[[ $(cat "$case_dir/curl-count") == 2 ]] || fail "truncated tool-round response dispatched another round"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "truncated tool-round response emitted candidate"
[[ $(cache_count) == 0 ]] || fail "truncated tool-round response cached"

# The auto-to-text compatibility fallback also propagates acceptance failure.
init_case truncated-fallback chat
mkdir -p "$case_dir/fixtures"
printf '400\n' >"$case_dir/fixtures/1.code"
cat >"$case_dir/fixtures/1.json" <<'JSON'
{"error":{"message":"invalid request"}}
JSON
cat >"$case_dir/fixtures/2.json" <<'JSON'
{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"echo provider-candidate"}}]}
JSON
invoke_engine auto
[[ $engine_status != 0 ]] || fail "truncated fallback unexpectedly succeeded"
[[ $(cat "$case_dir/curl-count") == 2 ]] || fail "truncated fallback request count"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "truncated fallback emitted candidate"
[[ $(cache_count) == 0 ]] || fail "truncated fallback cached"

# A syntax-repair retry cannot turn a truncated second answer into a candidate.
init_case truncated-repair chat
mkdir -p "$case_dir/fixtures"
cat >"$case_dir/fixtures/1.json" <<'JSON'
{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"echo 'unterminated"}}]}
JSON
cat >"$case_dir/fixtures/2.json" <<'JSON'
{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"echo provider-candidate"}}]}
JSON
invoke_engine
[[ $engine_status != 0 ]] || fail "truncated repair response unexpectedly succeeded"
[[ $(cat "$case_dir/curl-count") == 2 ]] || fail "syntax repair retry count"
[[ -z "$(candidates_of <<<"$engine_output")" ]] || fail "truncated repair emitted candidate"
[[ $(cache_count) == 0 ]] || fail "truncated repair cached"

# Seed an entry under the pre-revision request-derived key. The current engine
# must miss it, fetch a completed response, and then hit its new cache entry.
init_case legacy-command-cache chat
cat >"$case_dir/response.json" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo provider-cache"},"finish_reason":"stop"}]}
JSON
PATH="$fake_bin:$PATH" LMLINE_CONFIG_DIR="$case_dir/config" LMLINE_API_FORMAT=chat \
  LMLINE_TOOL_MODE=none "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" \
  --point 0 --line-file "$case_dir/line" --context-file "$case_dir/context" --n 1 \
  --dry-run-payload >"$case_dir/payload.json"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
line=$(cat "$case_dir/line")
legacy_key=$(
  {
    __lmline_request_key generate "$line"
    printf 'cwd=%s\n' "$repo_dir"
    printf 'base=%s\nmodel=%s\napi_format=%s\nn=%s\nmax_bytes=%s\nformat=%s\n' \
      https://api.test.invalid/v1 test-model chat 1 4096 annotated
    __lmline_hash_stdin <"$case_dir/payload.json"
  } | __lmline_hash_stdin
)
mkdir -p "$case_dir/config/cache"
printf 'lmline-candidate: low\tlegacy cache entry\t-\techo legacy-cache\n' >"$case_dir/config/cache/$legacy_key"
chmod 600 "$case_dir/config/cache/$legacy_key"
invoke_engine
[[ $engine_status == 0 ]] || fail "legacy command cache refetch status"
[[ "$(candidates_of <<<"$engine_output")" == 'echo provider-cache' ]] || fail "legacy command cache was not missed"
[[ $(cat "$case_dir/curl-count") == 1 ]] || fail "legacy command cache did not refetch"
invoke_engine
[[ $engine_status == 0 ]] || fail "fresh command cache hit status"
[[ "$(candidates_of <<<"$engine_output")" == 'echo provider-cache' ]] || fail "fresh command cache hit content"
[[ $(cat "$case_dir/curl-count") == 1 ]] || fail "fresh command cache missed"
grep -q 'cached' "$case_dir/stderr" || fail "fresh command cache status"

ok "provider truncation acceptance, fallback paths, and command cache revision"
