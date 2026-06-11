#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-engine-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model
printf '# list files\n' >"$cfg_tmp/line"
printf '## available_tools\n' >"$cfg_tmp/context"

fake_bin="$cfg_tmp/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
case "$count" in
  1)
    cat >"$out" <<'JSON'
{"model":"test/tool-model","usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11},"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"command_exists","arguments":"{\"commands\":\"awk\"}"}}]}}]}
JSON
    ;;
  2)
    cat >"$out" <<'JSON'
{"model":"test/tool-model","usage":{"prompt_tokens":12,"completion_tokens":2,"total_tokens":14},"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_2","type":"function","function":{"name":"command_info","arguments":"{\"commands\":\"awk\"}"}}]}}]}
JSON
    ;;
  *)
    cat >"$out" <<'JSON'
{"model":"test/final-model","usage":{"prompt_tokens":20,"completion_tokens":5,"total_tokens":25},"choices":[{"message":{"role":"assistant","content":"echo multi-round"}}]}
JSON
    ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
printf '# list files\n' >"$cfg_tmp/line"
printf '## available_tools\n' >"$cfg_tmp/context"
multi_round_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=openai LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$multi_round_out")" == "echo multi-round" ]] || fail "multi-round tool output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 3 ]] || fail "multi-round tool count"
printf '0\n' >"$cfg_tmp/fake-curl-state"
PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=openai LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 >/tmp/lmline-tool-progress.out 2>/tmp/lmline-tool-progress.err
grep -q '^lmline-progress: tool command-exists (openai, round 1/10)$' /tmp/lmline-tool-progress.err || fail "tool progress command_exists"
grep -q '^lmline-progress: tool command-info (openai, round 2/10)$' /tmp/lmline-tool-progress.err || fail "tool progress command_info"
grep -Eq '^lmline-meta: model=test/final-model tokens=50 prompt=42 completion=8 tools=command-exists,command-info time=[0-9]+s$' /tmp/lmline-tool-progress.err || fail "engine model/token/tool/time metadata"
printf '0\n' >"$cfg_tmp/fake-curl-state"
printf 'date -r\n' >"$cfg_tmp/line-explain"
explain_multi_round_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=openai LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line-explain" --context-file "$cfg_tmp/context" --n 1)
[[ "$explain_multi_round_out" == "echo multi-round" ]] || fail "explain multi-round tool output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 3 ]] || fail "explain multi-round tool count"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
case "$count" in
  1|2|3)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"command_info","arguments":"{\"commands\":\"echo\"}"}}]}}]}
JSON
    ;;
  *)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo trimmed-tools"}}]}
JSON
    ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
trace_dir="$cfg_tmp/trace-trim"
mkdir -p "$trace_dir"
trim_round_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TRACE_DIR="$trace_dir" LMLINE_TOOL_MODE=openai LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$trim_round_out")" == "echo trimmed-tools" ]] || fail "trimmed multi-round output"
! grep -R "\\[truncated\\]" "$trace_dir" >/dev/null || fail "tool message trimming disabled by default"
! find "$trace_dir" -name '*summary*' | grep -q . || fail "tool summarization disabled by default"
printf '0\n' >"$cfg_tmp/fake-curl-state"
trace_dir="$cfg_tmp/trace-summary-threshold"
mkdir -p "$trace_dir"
threshold_round_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TRACE_DIR="$trace_dir" LMLINE_TOOL_MODE=openai LMLINE_TOOL_RESULT_SUMMARIZE=1 LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS=999999 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$threshold_round_out")" == "echo trimmed-tools" ]] || fail "summary threshold output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 4 ]] || fail "summary threshold avoids extra request"
grep -R "below LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS" "$trace_dir" >/dev/null || fail "summary threshold trace"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
case "$count" in
  1|2|3)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"command_info","arguments":"{\"commands\":\"echo\"}"}}]}}]}
JSON
    ;;
  4)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"summary: echo is available and behaves as a shell builtin."}}]}
JSON
    ;;
  *)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo summarized-tools"}}]}
JSON
    ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
trace_dir="$cfg_tmp/trace-summary"
mkdir -p "$trace_dir"
summary_round_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TRACE_DIR="$trace_dir" LMLINE_TOOL_MODE=openai LMLINE_TOOL_RESULT_SUMMARIZE=1 LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS=1 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$summary_round_out")" == "echo summarized-tools" ]] || fail "summarized multi-round output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 5 ]] || fail "tool summary separate request"
grep -R "summary: echo is available" "$trace_dir" >/dev/null || fail "tool summary trace"
grep -R "Previous tool results summarized" "$trace_dir" >/dev/null || fail "tool summary message"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
case "$count" in
  1)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"tool command_exists awk"}}]}
JSON
    ;;
  2)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"Tool command_info commands=\"awk\" ; tool command_exists commands=sed"}}]}
JSON
    ;;
  *)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo text-tool-round"}}]}
JSON
    ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
text_tool_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=text LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$text_tool_out")" == "echo text-tool-round" ]] || fail "text tool output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 3 ]] || fail "text tool count"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"<thinking>\nreasoning\n</thinking>\n<THINK>\nstuff\n</THINK>\n<think >\nmore\n</think >\necho \"<think> about this\""}}]}
JSON
printf '200'
EOF
chmod +x "$fake_bin/curl"
thinking_out=$(PATH="$fake_bin:$PATH" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$thinking_out")" == 'echo "<think> about this"' ]] || fail "thinking tag stripping"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
url=${@: -1}
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  https://openrouter.ai/api/v1/chat/completions)
    cat >"$out" <<'JSON'
{"id":"gen-1","provider":"OpenRouter","choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"echo openrouter-ok"}}]}
JSON
    ;;
  https://generativelanguage.googleapis.com/v1beta/openai/chat/completions)
    cat >"$out" <<'JSON'
{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":[{"type":"text","text":"echo "},{"type":"text","text":"gemini-ok"}]}}]}
JSON
    ;;
  https://api.ai.sakura.ad.jp/v1/chat/completions)
    cat >"$out" <<'JSON'
{"model":"gpt-oss-120b","usage":{"prompt_tokens":11,"completion_tokens":3,"total_tokens":14},"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"echo sakura-ok"}}]}
JSON
    ;;
  *) echo "unexpected url: $url" >&2; exit 8 ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
openrouter_response_out=$(PATH="$fake_bin:$PATH" LMLINE_BASE_URL=https://openrouter.ai/api/v1 LMLINE_MODEL=openai/gpt-test LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/response-config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$openrouter_response_out")" == "echo openrouter-ok" ]] || fail "openrouter response content"
gemini_response_out=$(PATH="$fake_bin:$PATH" LMLINE_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai LMLINE_MODEL=gemini-2.5-flash LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/response-config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$gemini_response_out")" == "echo gemini-ok" ]] || fail "gemini response content array"
sakura_response_out=$(PATH="$fake_bin:$PATH" LMLINE_BASE_URL=https://api.ai.sakura.ad.jp/v1 LMLINE_MODEL=gpt-oss-120b LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/response-config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$sakura_response_out")" == "echo sakura-ok" ]] || fail "sakura response content"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
data=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
if [[ "$count" == 1 ]] && grep -q '"tools"' "$data"; then
  cat >"$out" <<'JSON'
{"choices":[{"finish_reason":"stop","native_finish_reason":"stop","message":{"role":"assistant","content":null}}]}
JSON
else
  cat >"$out" <<'JSON'
{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"echo recovered-without-tools"}}]}
JSON
fi
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
empty_auto_retry_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=auto LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$empty_auto_retry_out")" == "echo recovered-without-tools" ]] || fail "empty content auto retry"
[[ $(cat "$cfg_tmp/fake-curl-state") == 2 ]] || fail "empty content auto retry count"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
cat >"$out" <<'JSON'
{"choices":[{"finish_reason":"error","native_finish_reason":"provider_error","message":{"role":"assistant","content":null},"error":{"message":"upstream provider returned no content"}}]}
JSON
printf '200'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 >/tmp/lmline-choice-error.out 2>/tmp/lmline-choice-error.err; then
  fail "choice error unexpectedly succeeded"
fi
grep -q 'choice error: upstream provider returned no content' /tmp/lmline-choice-error.err || fail "choice error surfaced"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
data=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
if [[ "$count" == 1 ]] && grep -q '"tools"' "$data"; then
  printf '{"error":"tools unsupported"}\n' >"$out"
  printf '400'
  exit 0
fi
case "$count" in
  2)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"command_exists awk"}}]}
JSON
    ;;
  *)
    cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"echo auto-fallback"}}]}
JSON
    ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
auto_fallback_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$auto_fallback_out")" == "echo auto-fallback" ]] || fail "auto fallback output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 3 ]] || fail "auto fallback count"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
cat >"$out" <<'JSON'
{"choices":[{"message":{"role":"assistant","content":"# list files"}}]}
JSON
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
if PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 >/tmp/lmline-same-retry.out 2>/tmp/lmline-same-retry.err; then
  fail "same-as-input retry unexpectedly succeeded"
fi
[[ $(cat "$cfg_tmp/fake-curl-state") == 1 ]] || fail "same-as-input should not retry"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
long=$(printf "printf %%s "; printf "a%.0s" {1..5000})
printf '{"choices":[{"message":{"role":"assistant","content":%s}}]}\n' "$(jq -Rn --arg s "$long" '$s')" >"$out"
printf '200'
EOF
chmod +x "$fake_bin/curl"
PATH="$fake_bin:$PATH" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 >/tmp/lmline-too-long.out 2>/tmp/lmline-too-long.err
[[ $(candidates_of </tmp/lmline-too-long.out | LC_ALL=C wc -c | tr -d ' ') -le 4097 ]] || fail "too-long candidate output not truncated"
grep -q 'candidate-truncated' /tmp/lmline-too-long.err || fail "too-long candidate truncation marker"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
case "$count" in
  1) printf '{"choices":[{"message":{"role":"assistant","content":"echo \\"unterminated"}}]}\n' >"$out" ;;
  *) printf '{"choices":[{"message":{"role":"assistant","content":"echo retry-ok"}}]}\n' >"$out" ;;
esac
printf '200'
EOF
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
retry_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
[[ "$(candidates_of <<<"$retry_out")" == "echo retry-ok" ]] || fail "shell-syntax retry output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 2 ]] || fail "shell-syntax retry count"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
printf '<html>unauthorized</html>\n' >"$out"
printf '401'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 >/tmp/lmline-non-json.out 2>/tmp/lmline-non-json.err; then
  fail "non-json error unexpectedly succeeded"
fi
grep -q 'non-JSON error response' /tmp/lmline-non-json.err || fail "non-json error detail"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
printf '{"error":{"message":"bad key message"}}\n' >"$out"
printf '401\tapplication/json'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 >/tmp/lmline-json-error.out 2>/tmp/lmline-json-error.err; then
  fail "json error unexpectedly succeeded"
fi
grep -q 'bad key message' /tmp/lmline-json-error.err || fail "json error message detail"
warn_payload_err=$(LMLINE_CONFIG_DIR="$cfg_tmp/noauth-config" LMLINE_BASE_URL=https://api.openai.com/v1 LMLINE_API_KEY_FILE= LMLINE_MODEL=test "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --dry-run-payload >/tmp/lmline-warn-payload.out 2>&1 || true)
grep -q 'warning: no API key configured' /tmp/lmline-warn-payload.out || fail "cloud api key warning"
sakura_warn_payload_err=$(LMLINE_CONFIG_DIR="$cfg_tmp/noauth-config" LMLINE_BASE_URL=https://api.ai.sakura.ad.jp/v1 LMLINE_API_KEY_FILE= LMLINE_MODEL=gpt-oss-120b "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --dry-run-payload >/tmp/lmline-sakura-warn-payload.out 2>&1 || true)
grep -q 'warning: no API key configured' /tmp/lmline-sakura-warn-payload.out || fail "sakura api key warning"
LMLINE_CONFIG_DIR="$cfg_tmp/noauth-config" LMLINE_BASE_URL=http://127.0.0.1:1234/v1 LMLINE_API_KEY_FILE= LMLINE_MODEL=test "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --dry-run-payload >/tmp/lmline-local-payload.out 2>&1 || true
! grep -q 'warning: no API key configured' /tmp/lmline-local-payload.out || fail "local api key warning"
if LMLINE_CONFIG_DIR="$cfg_tmp/config" LMLINE_TEMPERATURE=bad "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --dry-run-payload >/tmp/lmline-bad-temperature.out 2>/tmp/lmline-bad-temperature.err; then
  fail "invalid engine temperature rejected"
fi
grep -q "invalid LMLINE_TEMPERATURE" /tmp/lmline-bad-temperature.err || fail "invalid engine temperature error"

ok "engine"
