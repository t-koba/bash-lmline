#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-features-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
fake_bin="$cfg_tmp/bin"
mkdir -p "$fake_bin" "$cfg_tmp/config"
printf '# say hi\n' >"$cfg_tmp/line"
printf '## shell\n' >"$cfg_tmp/context"

engine_env=(LMLINE_CONFIG_DIR="$cfg_tmp/config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model)
run_engine() {
  env PATH="$fake_bin:$PATH" "${engine_env[@]}" "$@" \
    "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
    --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1
}

# --- annotated protocol: risk, reason, and truncated flags ------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
printf '%s' '{"model":"m","choices":[{"message":{"content":"rm -rf /tmp/x\necho safe"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
chmod +x "$fake_bin/curl"
annotated_out=$(run_engine LMLINE_TOOL_MODE=none 2>/dev/null) || fail "annotated engine run"
grep -q $'^lmline-candidate: high\trecursive remove\t-\trm -rf /tmp/x$' <<<"$annotated_out" || fail "annotated high risk line"
plain_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
  --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --format plain 2>/dev/null) || fail "plain engine run"
[[ "$plain_out" == "rm -rf /tmp/x" ]] || fail "plain format output"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
long=$(printf "printf %%s "; printf "a%.0s" {1..5000})
printf '{"choices":[{"message":{"content":%s},"finish_reason":"stop"}]}' "$(jq -Rn --arg s "$long" '$s')" >"$out"
printf '200\tapplication/json'
EOF
truncated_out=$(run_engine LMLINE_TOOL_MODE=none 2>/dev/null) || fail "truncated engine run"
grep -q $'\ttruncated\t' <<<"$truncated_out" || fail "truncated flag annotated"
[[ $(candidates_of <<<"$truncated_out" | LC_ALL=C wc -c | tr -d ' ') -le 4097 ]] || fail "truncated candidate length"

# --- 429 retry ---------------------------------------------------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
if (( count == 1 )); then
  printf '' >"$out"
  printf '429\tapplication/json'
else
  printf '{"choices":[{"message":{"content":"echo retried"},"finish_reason":"stop"}]}' >"$out"
  printf '200\tapplication/json'
fi
EOF
printf '0\n' >"$cfg_tmp/retry-state"
retry_out=$(run_engine LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/retry-state" LMLINE_RETRY_DELAY=0 2>"$cfg_tmp/retry.err") || fail "retry engine run"
[[ "$(candidates_of <<<"$retry_out")" == "echo retried" ]] || fail "429 retry output"
[[ $(cat "$cfg_tmp/retry-state") == 2 ]] || fail "429 retry count"
grep -q 'lmline-progress: transient provider error; retrying (1/1)' "$cfg_tmp/retry.err" || fail "429 retry progress"
printf '0\n' >"$cfg_tmp/retry-state"
if run_engine LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/retry-state" LMLINE_RETRY_DELAY=0 LMLINE_HTTP_RETRIES=0 >/dev/null 2>"$cfg_tmp/retry0.err"; then
  fail "retries disabled should fail on 429"
fi
[[ $(cat "$cfg_tmp/retry-state") == 1 ]] || fail "retries disabled request count"

# --- response cache ----------------------------------------------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
printf '{"model":"m","choices":[{"message":{"content":"echo cached-cmd"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
printf '0\n' >"$cfg_tmp/cache-state"
cache_env=(LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/cache-state" LMLINE_CACHE_TTL=300)
first_out=$(run_engine "${cache_env[@]}" 2>/dev/null) || fail "cache first run"
second_out=$(run_engine "${cache_env[@]}" 2>"$cfg_tmp/cache.err") || fail "cache second run"
[[ "$first_out" == "$second_out" ]] || fail "cache hit output identical"
[[ $(cat "$cfg_tmp/cache-state") == 1 ]] || fail "cache hit avoids provider request"
grep -q 'lmline-status: m=test-model; cached' "$cfg_tmp/cache.err" || fail "cache hit status"
cache_entry=$(find "$cfg_tmp/config/cache" -maxdepth 1 -type f | sed -n '1p')
[[ -n "$cache_entry" ]] || fail "cache entry exists"
touch -t 202001010000 "$cache_entry"
third_out=$(run_engine "${cache_env[@]}" 2>/dev/null) || fail "cache expired run"
[[ $(cat "$cfg_tmp/cache-state") == 2 ]] || fail "expired cache refetches"
[[ "$(candidates_of <<<"$third_out")" == "echo cached-cmd" ]] || fail "expired cache output"

# --- streaming (explain, tool mode none) -------------------------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"<think>\n"}}]}'
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"secret reasoning\n</think>\nstreamed "}}]}'
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"explanation line\nsecond line"}}]}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
echo "unexpected non-stream request" >&2
exit 9
EOF
printf 'echo hi\n' >"$cfg_tmp/explain-line"
stream_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/stream.err") || fail "stream engine run"
[[ "$stream_out" == $'streamed explanation line\nsecond line' ]] || fail "stream output"
! grep -q 'secret reasoning' <<<"$stream_out" || fail "stream think stripping"
grep -q '^lmline-status: ' "$cfg_tmp/stream.err" || fail "stream status line"

# Stream with no content falls back to the buffered request.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
out=
while (($#)); do
  case "$1" in
    -N) is_stream=1; shift ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
if (( is_stream )); then
  printf 'data: [DONE]\n\n'
  exit 0
fi
printf '{"choices":[{"message":{"content":"buffered fallback"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
fallback_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/fallback.err") || fail "stream fallback run"
[[ "$fallback_out" == "buffered fallback" ]] || fail "stream fallback output"
grep -q 'streaming unavailable; continuing with a buffered request' "$cfg_tmp/fallback.err" || fail "stream fallback progress"

# Streamed usage chunk (stream_options.include_usage) fills the status line.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"usage answer\n"}}]}'
  printf '%s\n\n' 'data: {"model":"usage-model","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
echo "unexpected non-stream request" >&2
exit 9
EOF
usage_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/usage.err") || fail "stream usage run"
[[ "$usage_out" == "usage answer" ]] || fail "stream usage output"
grep -q 'lmline-status: m=usage-model; tok=7/3/10' "$cfg_tmp/usage.err" || fail "stream usage status tokens"

# Streamed output respects the explain byte budget and emits a marker.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"first line ok\nsecond line is far beyond the byte budget\nthird line too\n"}}]}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
echo "unexpected non-stream request" >&2
exit 9
EOF
limit_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 LMLINE_EXPLAIN_MAX_OUTPUT_BYTES=20 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>/dev/null) || fail "stream limit run"
grep -q '^first line ok$' <<<"$limit_out" || fail "stream limit kept first line"
! grep -q 'second line' <<<"$limit_out" || fail "stream limit dropped over-budget line"
grep -q 'explanation-truncated original_bytes=.* max_bytes=20' <<<"$limit_out" || fail "stream limit marker"

# Streaming drives the tool loop: a native tool-call round runs locally and
# the final answer still streams.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
(( is_stream )) || { echo "unexpected non-stream request" >&2; exit 9; }
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
if (( count == 1 )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"command_exists","arguments":""}}]}}]}'
  printf '%s\n\n' 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"commands\":\"awk\"}"}}]}}]}'
  printf 'data: [DONE]\n\n'
else
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"tool-informed answer\n"}}]}'
  printf 'data: [DONE]\n\n'
fi
exit 0
EOF
printf '0\n' >"$cfg_tmp/stream-tool-state"
stream_tool_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=openai LMLINE_STREAM=1 \
  LMLINE_FAKE_CURL_STATE="$cfg_tmp/stream-tool-state" \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/stream-tool.err") || fail "stream tool run"
[[ "$stream_tool_out" == "tool-informed answer" ]] || fail "stream tool final output"
[[ $(cat "$cfg_tmp/stream-tool-state") == 2 ]] || fail "stream tool round count"
grep -q 'lmline-progress: tool command-exists (openai, round 1/10)' "$cfg_tmp/stream-tool.err" || fail "stream tool progress"
grep -q 'lmline-status: .*tools=command-exists' "$cfg_tmp/stream-tool.err" || fail "stream tool status"

# --- endpoint/model CRUD and use auto-select ---------------------------------
crud_dir="$cfg_tmp/crud"
lm() { LMLINE_CONFIG_DIR="$crud_dir" "$repo_dir/lmline/lmline" "$@"; }
lm endpoint add ep https://crud.example/v1 >/dev/null
lm endpoint set-secret ep crud-secret 2>"$cfg_tmp/secret-warn.err" >/dev/null
grep -q 'leak via shell history' "$cfg_tmp/secret-warn.err" || fail "set-secret argv warning"
lm model add ep solo-model >/dev/null
lm use ep >/dev/null || fail "use auto-select single model"
grep -q "LMLINE_MODEL=.*solo-model" "$crud_dir/settings.bash" || fail "use auto-select persisted"
lm model add ep second-model >/dev/null
if lm use ep >/dev/null 2>"$cfg_tmp/use-multi.err"; then
  fail "use with multiple models must fail"
fi
grep -q 'lmline use ep solo-model' "$cfg_tmp/use-multi.err" || fail "use multi hint"
lm model remove ep second-model || fail "model remove"
! lm model list ep | grep -q second-model || fail "model removed from list"
secret_path=$(awk -F '\t' '$1 == "ep" { print $5 }' "$crud_dir/endpoints.tsv")
[[ -f "$secret_path" ]] || fail "secret exists before endpoint remove"
lm endpoint remove ep 2>/dev/null || fail "endpoint remove"
[[ ! -f "$secret_path" ]] || fail "endpoint remove deletes secret"
! lm endpoint list | grep -q '^ep' || fail "endpoint removed from list"
[[ -z "$(lm model list ep)" ]] || fail "endpoint remove drops models"

# config set accepts an explicitly empty value (raw-header auth scheme).
lm config set LMLINE_AUTH_SCHEME '' || fail "config set empty value"
grep -q "^export LMLINE_AUTH_SCHEME=''" "$crud_dir/settings.bash" || fail "empty value persisted"
if lm config set LMLINE_AUTH_SCHEME >/dev/null 2>&1; then
  fail "config set without value must fail"
fi

# --- risk normalization --------------------------------------------------------
risk_of() { LMLINE_CONFIG_DIR="$crud_dir" "$repo_dir/lmline/lmline" risk "$1" | sed -n 's/^risk=//p'; }
[[ $(risk_of 'dd if=/dev/zero of=/dev/null') == high ]] || fail "risk dd at line start"
[[ $(risk_of 'dd') == high ]] || fail "risk bare dd"
[[ $(risk_of 'cat f | dd of=/dev/null') == high ]] || fail "risk dd mid-pipeline"
[[ $(risk_of 'mkfs.ext4 /dev/sda1') == high ]] || fail "risk mkfs at line start"
[[ $(risk_of 'sudo ls') == high ]] || fail "risk sudo at line start"
[[ $(risk_of 'echo dde') == low ]] || fail "risk no false positive on substring"

ok "features (protocol, retry, cache, stream, crud, risk)"
