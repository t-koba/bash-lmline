#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-stream-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model
printf 'ls -la\n' >"$cfg_tmp/line"
printf '## available_tools\n' >"$cfg_tmp/context"
fake_bin="$cfg_tmp/fake-bin"
mkdir -p "$fake_bin"

run_stream_engine() {
  PATH="$fake_bin:$PATH" LMLINE_STREAM=1 LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" \
    "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 0 \
    --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1
}

# A stream that dies mid-answer (no [DONE], curl exit 56) after emitting
# content must be flagged as interrupted instead of ending silently.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
streaming=0
out=
while (($#)); do
  case "$1" in
    -N) streaming=1; shift ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
if (( streaming )); then
  cat <<'SSE'
data: {"choices":[{"delta":{"content":"streamed explanation line\n"}}]}

data: {"choices":[{"delta":{"content":"cut off"}}]}

SSE
  exit 56
fi
cat >"$out" <<'JSON'
{"model":"m","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"message":{"role":"assistant","content":"buffered explanation"},"finish_reason":"stop"}]}
JSON
printf '200'
EOF
chmod +x "$fake_bin/curl"
interrupted_out=$(run_stream_engine)
grep -q 'streamed explanation line' <<<"$interrupted_out" || fail "interrupted stream content"
grep -q '^stream-interrupted emitted_bytes=' <<<"$interrupted_out" || fail "stream-interrupted marker"

# A stream that dies before any content reached the user must fall back to
# the buffered request instead of returning an empty answer.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
streaming=0
out=
while (($#)); do
  case "$1" in
    -N) streaming=1; shift ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
if (( streaming )); then
  cat <<'SSE'
data: {"choices":[{"delta":{"role":"assistant"}}]}

SSE
  exit 56
fi
cat >"$out" <<'JSON'
{"model":"m","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"message":{"role":"assistant","content":"buffered explanation"},"finish_reason":"stop"}]}
JSON
printf '200'
EOF
chmod +x "$fake_bin/curl"
fallback_out=$(run_stream_engine)
grep -q 'buffered explanation' <<<"$fallback_out" || fail "empty interrupted stream falls back to buffered"
! grep -q '^stream-interrupted' <<<"$fallback_out" || fail "fallback output has no interrupted marker"

# A complete stream ([DONE] received) must not be flagged as interrupted.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
streaming=0
out=
while (($#)); do
  case "$1" in
    -N) streaming=1; shift ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
if (( streaming )); then
  cat <<'SSE'
data: {"choices":[{"delta":{"content":"complete explanation"},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

SSE
  exit 0
fi
cat >"$out" <<'JSON'
{"model":"m","choices":[{"message":{"role":"assistant","content":"should not be used"},"finish_reason":"stop"}]}
JSON
printf '200'
EOF
chmod +x "$fake_bin/curl"
complete_out=$(run_stream_engine)
grep -q 'complete explanation' <<<"$complete_out" || fail "complete stream content"
! grep -q '^stream-interrupted' <<<"$complete_out" || fail "complete stream has no interrupted marker"

ok "stream interruption handling"
