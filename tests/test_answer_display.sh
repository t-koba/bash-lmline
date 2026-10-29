#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: answer controls reach a terminal, or filtering damages UTF-8/streaming.
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/actions.bash
source "$repo_dir/lmline/actions.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-answer-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# No fixtures or captured model bodies are printed on failure.
for sequence in $'\e[2J' $'\e[?25l' $'\e]0;title\a' $'\e]52;c;payload\e\\' \
  $'\ePpayload\e\\' $'\eXpayload\e\\' $'\e^payload\e\\' $'\e_payload\e\\' \
  $'\e(B' $'\ec' $'\2332J' $'\302\2332J' $'\235title\234' $'\302\235title\302\234'; do
  out=$(printf 'left%sright\n' "$sequence" | __lmline_display_answer)
  [[ "$out" == leftright ]] || fail "terminal sequence removed"
done
# Every C0/C1/DEL control other than LF; include NUL via a pipe, not a shell var.
for ((code=0; code<160; code++)); do
  (( code == 10 || (code >= 32 && code < 127) )) && continue
  printf -v octal '%03o' "$code"
  out=$(printf 'left%b\nright\n' "\\$octal" | __lmline_display_answer)
  [[ "$out" == $'left\nright' ]] || fail "terminal control removed"
done
plain=$'ASCII [brackets] \\ slash\n\nUTF-8: \303\251 \346\227\245 \360\237\230\200\nend'
for locale in C C.UTF-8; do
  out=$(printf '%s\n' "$plain" | LC_ALL="$locale" __lmline_display_answer)
  [[ "$out" == "$plain" ]] || fail "ordinary UTF-8 and LF preserved"
done
out=$(printf 'a\e]unfinished\nb\e[\nc\n' | __lmline_display_answer)
[[ "$out" == $'a\nb\nc' ]] || fail "unfinished sequences cannot hide later lines"

# Process startup must stay bounded per answer, not grow with unsafe lines.
# Wrap the existing dependency; count calls, never captured answer content.
awk() {
  printf 'call\n' >>"$tmp/awk-calls"
  command awk "$@"
}
for controls in 0 1; do
  : >"$tmp/awk-calls"
  for ((line_number=0; line_number<300; line_number++)); do
    printf 'UTF-8: \303\251 \346\227\245 \360\237\230\200'
    (( controls == 0 )) || printf '\e[31m\e]52;c;payload\a\e[0m'
    printf ' end\n'
  done >"$tmp/batch-input"
  __lmline_display_answer <"$tmp/batch-input" >"$tmp/batch-output"
  for ((line_number=0; line_number<300; line_number++)); do
    printf 'UTF-8: \303\251 \346\227\245 \360\237\230\200 end\n'
  done >"$tmp/batch-expected"
  cmp -s "$tmp/batch-expected" "$tmp/batch-output" || fail "batch UTF-8 preserved and controls removed"
  calls=$(wc -l <"$tmp/awk-calls")
  (( calls <= 2 )) || fail "answer renderer process count bounded"
done
unset -f awk

# A failed implementation probe is not fatal, but a failed renderer is.
# This also exercises the non-mawk fallback with strict caller options.
awk() { return 43; }
status=0
__lmline_display_answer <<<"ordinary input" >"$tmp/awk-failure" || status=$?
[[ "$status" == 43 ]] || fail "awk renderer failure preserved"
unset -f awk

# Near-cap lines retain UTF-8, even when controls sit at both ends and there
# is no final LF. Assert exact content without logging answer bodies.
printf -v large '%*s' 32750 ''
large=${large// /$'\303\251'}
out=$(printf '\e[31m%s\e[0m' "$large" | __lmline_display_answer)
[[ "$out" == "$large" ]] || fail "near-cap line preserved"

# The stream engine still counts/stores raw answer bytes. The display does not
# backfill stripped bytes, and trusted truncation notices remain untouched.
stream_fixture() {
  local mode=$1 stream_skip=0 stream_budget=8 content_bytes=0 emitted_bytes=0 stream_truncated=0
  local emitted_file=$tmp/raw-stream
  : >"$emitted_file"
  __lmline_stream_handle_line $'A\e[31mB' || fail "first raw stream line accepted"
  if __lmline_stream_handle_line C; then fail "raw stream budget enforced"; fi
  [[ "$emitted_bytes" == 8 && "$content_bytes" == 10 && "$stream_truncated" == 1 ]] || fail "raw stream accounting"
  [[ $(cat "$emitted_file") == $'A\e[31mB' ]] || fail "raw stream cache data preserved"
  printf '%s original_bytes=10 max_bytes=8\n' "$mode"
}
for notice in explanation-truncated clip-output-truncated; do
  out=$(stream_fixture "$notice" | __lmline_display_answer)
  [[ "$out" == $'AB\n'"$notice original_bytes=10 max_bytes=8" ]] || fail "stream controls removed after raw budgeting"
done

# A FIFO handshake proves the first line is visible before the engine finishes.
# Timed reads bound regressions without polling or sustained load.
mkfifo "$tmp/ready" "$tmp/live"
exec 8<>"$tmp/ready" 9<>"$tmp/live"
live_engine() {
  printf '\e[31mfirst\e[0m\n'
  local ready
  IFS= read -r -t 5 ready <&8 || return 77
  [[ "$ready" == ready ]] || return 78
  printf 'second\n'
}
__lmline_action_stream_engine '' "$tmp/stderr" live_engine >"$tmp/live" &
pid=$!
IFS= read -r -t 3 first <&9 || { wait "$pid" || true; fail "stream line flushed before engine completion"; }
[[ "$first" == first ]] || fail "first stream line sanitized"
printf 'ready\n' >&8
IFS= read -r -t 3 second <&9 || fail "second stream line available"
wait "$pid" || fail "live stream status"
[[ "$second" == second ]] || fail "live stream text preserved"
exec 8>&- 9>&-

failing_engine() { printf 'partial\n'; return 23; }
# These checks intentionally catch locale overrides confined to subshells.
# shellcheck disable=SC2031
before_options=$- before_set=$(set +o) before_shopt=$(shopt -p) before_locale=$LC_ALL
status=0
__lmline_action_stream_engine '' "$tmp/stderr" failing_engine >"$tmp/failure" || status=$?
[[ "$status" == 23 ]] || fail "engine failure status preserved"
# shellcheck disable=SC2031
[[ "$-" == "$before_options" && "$(set +o)" == "$before_set" && "$(shopt -p)" == "$before_shopt" && "$LC_ALL" == "$before_locale" ]] || fail "caller state preserved"

# Renderer failures are not masked. Boolean-only: no untrusted bytes reach the log.
orig_display_answer=$(declare -f __lmline_display_answer)
__lmline_display_answer() { cat >/dev/null; return 41; }
succeeding_engine() { printf 'ok\n'; return 0; }
# shellcheck disable=SC2031
before_options=$- before_set=$(set +o) before_shopt=$(shopt -p) before_locale=$LC_ALL
status=0
__lmline_action_stream_engine '' "$tmp/stderr" succeeding_engine >"$tmp/renderer-failure" || status=$?
[[ "$status" == 41 ]] || fail "renderer failure status preserved"
# shellcheck disable=SC2031
[[ "$-" == "$before_options" && "$(set +o)" == "$before_set" && "$(shopt -p)" == "$before_shopt" && "$LC_ALL" == "$before_locale" ]] || fail "caller state preserved"
status=0
__lmline_action_stream_engine '' "$tmp/stderr" failing_engine >"$tmp/both-failure" || status=$?
[[ "$status" == 23 ]] || fail "engine failure takes precedence over renderer"
eval "$orig_display_answer"

# Truncated buffered branches propagate renderer failures instead of returning zero.
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"
cat >"$tmp/fake-answer-engine" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "ABCDEFGH"
EOF
chmod +x "$tmp/fake-answer-engine"
orig_display_answer=$(declare -f __lmline_display_answer)
__lmline_display_answer() { cat >/dev/null; return 42; }
status=0
LMLINE_EXPLAIN_MAX_OUTPUT_BYTES=7 LMLINE_STREAM=0 __lmline_print_explanation "$tmp/fake-answer-engine" bash 'echo hi' 7 '[lm] ' >"$tmp/explain-renderer-failure" 2>&1 || status=$?
[[ "$status" == 42 ]] || fail "truncated explanation renderer failure preserved"
orig_clipboard_read=$(declare -f __lmline_clipboard_read)
__lmline_clipboard_read() { printf 'clipboard'; }
status=0
LMLINE_CLIP_MAX_OUTPUT_BYTES=7 LMLINE_STREAM=0 __lmline_print_clip "$tmp/fake-answer-engine" bash 'question' '[lm] ' >"$tmp/clip-renderer-failure" 2>&1 || status=$?
[[ "$status" == 42 ]] || fail "truncated clip renderer failure preserved"
eval "$orig_display_answer"
eval "$orig_clipboard_read"
ok 'terminal-safe answer display'
