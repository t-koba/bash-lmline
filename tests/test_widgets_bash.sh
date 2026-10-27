#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: interactive Bash Readline widgets preserve candidate cycling, async generation, review, and cancellation.

widget_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-widget-test.XXXXXX")
printf '#!/usr/bin/env bash\nprintf "lmline-status: m=widget-model; tok=100/23/123\\n" >&2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo one\\nlmline-candidate: low\\tno matching risk rule\\t-\\techo two\\n"\n' >"$widget_tmp/engine"
chmod +x "$widget_tmp/engine"
cat >"$widget_tmp/engine-function" <<'EOF'
#!/usr/bin/env bash
if ! printf '%s\n' "${LMLINE_SHELL_FUNCTIONS-}" | grep -Fxq 'lmline/widget-function-probe'; then
  exit 1
fi
printf 'lmline-candidate: low\tno matching risk rule\t-\tlmline/widget-function-probe\n'
EOF
chmod +x "$widget_tmp/engine-function"
# Exercise the portable digest and ensure failed identities never match a job.
mkdir "$widget_tmp/hash-bin"
for cmd in bash sort cksum cut; do ln -s "$(command -v "$cmd")" "$widget_tmp/hash-bin/$cmd"; done
mkdir "$widget_tmp/fail-hash-bin"
for cmd in bash sort; do ln -s "$(command -v "$cmd")" "$widget_tmp/fail-hash-bin/$cmd"; done
printf '#!/bin/sh\nprintf "bad digest\\n"\nexit 1\n' >"$widget_tmp/fail-hash-bin/cksum"
chmod +x "$widget_tmp/fail-hash-bin/cksum"
mkdir "$widget_tmp/fail-sort-bin"
printf '#!/bin/sh\nprintf "LMLINE_MODEL\\n"\nexit 1\n' >"$widget_tmp/fail-sort-bin/sort"
chmod +x "$widget_tmp/fail-sort-bin/sort"
LMLINE_CONFIG_DIR="$widget_tmp/config-hash" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  (
    export PATH="$2/hash-bin" LMLINE_MODEL=first
    a=$(__lmline_async_settings_key)
    [[ "$a" =~ ^[0-9]+[[:space:]][0-9]+$ ]]
    [[ "$a" == "$(__lmline_async_settings_key)" ]]
    export LMLINE_MODEL=second
    [[ "$a" != "$(__lmline_async_settings_key)" ]]
  )
  ( export PATH="$2/fail-hash-bin"; ! __lmline_async_settings_key >/dev/null )
  __lmline_async_function_names_key() { printf names; }
  __lmline_hint() { :; }
  __lmline_async_cleanup() { :; }
  __lmline_async_start() { rm -f "$4"; __LMLINE_ASYNC_KEY=$5; __LMLINE_ASYNC_PID=$$; starts=$((starts + 1)); }
  starts=0
  __lmline_generate_async_widget input generate 0
  [[ $starts == 1 && -n "$__LMLINE_ASYNC_KEY" ]]
  export PATH="$2/fail-sort-bin:$PATH"
  command -v cksum >/dev/null
  ! __lmline_async_settings_key >/dev/null
  __lmline_generate_async_widget input generate 0
  [[ $starts == 2 && -z "$__LMLINE_ASYNC_KEY" ]]
  __lmline_generate_async_widget input generate 0
  [[ $starts == 3 && -z "$__LMLINE_ASYNC_KEY" ]]
' _ "$repo_dir" "$widget_tmp" || fail "bash portable settings hash and failed identity"
LMLINE_CONFIG_DIR="$widget_tmp/config-function" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-function" LMLINE_HISTORY_DIR="$widget_tmp/history-function" LMLINE_WIDGET_FUNCTION_MARKER="$widget_tmp/function-called" bash --norc -e -i -c '
  lmline/widget-function-probe() { : >"$LMLINE_WIDGET_FUNCTION_MARKER"; }
  source "$1/lmline/init.bash"
  READLINE_LINE="# call the shell function"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-function.out 2>/tmp/lmline-widget-function.err
  [[ "$READLINE_LINE" == "lmline/widget-function-probe" ]]
  [[ ! -e "$LMLINE_WIDGET_FUNCTION_MARKER" ]]
' _ "$repo_dir" || fail "bash widget hands off function names without executing them"
# Child interactive Bash shells enable errexit explicitly; parent shell options do not propagate.
LMLINE_CONFIG_DIR="$widget_tmp/config" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine" LMLINE_HISTORY_DIR="$widget_tmp/history" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  [[ $(__lmline_infer_mode "# request") == generate ]]
  [[ $(__lmline_infer_mode "#another request") == generate ]]
  [[ $(__lmline_infer_mode "") == generate ]]
  [[ $(__lmline_infer_mode "ls | ") == generate ]]
  [[ $(__lmline_infer_mode "ls |") == generate ]]
  [[ $(__lmline_infer_mode $'"'"'ls |\t'"'"') == generate ]]
  [[ $(__lmline_infer_mode "request") == generate ]]
  [[ $(__lmline_infer_mode "printf foo") == generate ]]
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-sync.out 2>/tmp/lmline-widget-sync.err
  [[ "$READLINE_LINE" == "echo one" ]]
  grep -q "2 candidates; m=widget-model; tok=100/23/123" /tmp/lmline-widget-sync.err
' _ "$repo_dir" || fail "sync widget"
# A flag marker is present only as a whole one: a token that merely carries
# the word does not mark the candidate.
printf '#!/usr/bin/env bash\nprintf "lmline-candidate: low\\tno matching risk rule\\tcopilot:truncated-token\\techo one\\n"\n' >"$widget_tmp/engine-copilot-token"
chmod +x "$widget_tmp/engine-copilot-token"
LMLINE_CONFIG_DIR="$widget_tmp/config-copilot-token" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-copilot-token" LMLINE_HISTORY_DIR="$widget_tmp/history-copilot-token" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-copilot-token.out 2>/tmp/lmline-widget-copilot-token.err
  ! grep -q "candidate-truncated" /tmp/lmline-widget-copilot-token.err
' _ "$repo_dir" || fail "a copilot token does not mark the candidate truncated"
# The suggestion log holds the user own command lines, so it stays user-only.
LMLINE_CONFIG_DIR="$widget_tmp/config-mode" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine" LMLINE_HISTORY_DIR="$widget_tmp/history-mode" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  __lmline_record_suggestion "generate" "# say one" "echo one"
  [[ -f "$LMLINE_HISTORY_DIR/suggestions.log" ]]
  [[ $(ls -ld "$LMLINE_HISTORY_DIR" | cut -c2-10) == rwx------ ]]
  [[ $(ls -l "$LMLINE_HISTORY_DIR/suggestions.log" | cut -c2-10) == rw------- ]]
' _ "$repo_dir" || fail "the suggestion log stays user-only"
printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: curl: (28) Operation timed out after 12003 milliseconds with 0 bytes received\\n" >&2\nexit 1\n' >"$widget_tmp/engine-fail"
chmod +x "$widget_tmp/engine-fail"
LMLINE_CONFIG_DIR="$widget_tmp/config-fail" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-fail" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-fail.out 2>/tmp/lmline-widget-fail.err
  [[ "$READLINE_LINE" == "# say one" ]]
  grep -q "request timed out" /tmp/lmline-widget-fail.err
  grep -q "LMLINE_ENGINE_TIMEOUT" /tmp/lmline-widget-fail.err
' _ "$repo_dir" || fail "engine failure is surfaced"
printf '#!/usr/bin/env bash\nprintf "lmline-candidate: medium\\twrites to a file or descriptor\\t-\\techo hi > out.txt\\n"\n' >"$widget_tmp/engine-medium"
chmod +x "$widget_tmp/engine-medium"
LMLINE_CONFIG_DIR="$widget_tmp/config-medium" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-medium" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# medium"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-medium.out 2>/tmp/lmline-widget-medium.err
  [[ "$READLINE_LINE" == "echo hi > out.txt" ]]
  grep -q "medium-risk; review before Enter" /tmp/lmline-widget-medium.err
' _ "$repo_dir" || fail "bash medium risk hint"
printf '#!/usr/bin/env bash\nprintf "lmline-candidate: high\\trecursive remove\\t-\\trm -rf /tmp/lmline-risk-test\\n"\n' >"$widget_tmp/engine-high"
chmod +x "$widget_tmp/engine-high"
LMLINE_CONFIG_DIR="$widget_tmp/config-high" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine-high" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# high"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-high.out 2>/tmp/lmline-widget-high.err
  [[ "$READLINE_LINE" == "# REVIEW REQUIRED: rm -rf /tmp/lmline-risk-test" ]]
  grep -q "high-risk; inserted as comment" /tmp/lmline-widget-high.err
' _ "$repo_dir" || fail "bash high risk hint"
cat >"$widget_tmp/engine-explain" <<'EOF'
#!/usr/bin/env bash
mode=
line_file=
while (($#)); do
  case "$1" in
    --mode) mode=$2; shift 2 ;;
    --line-file) line_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$mode" == explain ]]; then
  printf 'lmline-meta: model=explain-model tokens=66 prompt=50 completion=16\n' >&2
  printf 'lmline-status: m=explain-model; tok=50/16/66\n' >&2
  printf 'explained command\n'
  [[ -n "$line_file" ]] && printf 'line-bytes=%s\n' "$(wc -c <"$line_file")"
else
  printf 'lmline-candidate: low\tno matching risk rule\t-\techo default\n'
fi
EOF
chmod +x "$widget_tmp/engine-explain"
long_explain_cmd=$(printf "printf %s " "%s"; printf "'"; printf "b%.0s" {1..5000}; printf "'")
LMLINE_CONFIG_DIR="$widget_tmp/config-explain" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="echo hi"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_explain_widget >/tmp/lmline-widget-explain.out 2>/tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] command: echo hi" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] risk=low" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] command summary:" /tmp/lmline-widget-explain.err
  grep -q "^echo is" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] model explanation:" /tmp/lmline-widget-explain.err
  grep -q "\\[lm\\] m=explain-model; tok=50/16/66" /tmp/lmline-widget-explain.err
  grep -q "explained command" /tmp/lmline-widget-explain.err
' _ "$repo_dir" || fail "bash explain widget"
LMLINE_CONFIG_DIR="$widget_tmp/config-explain-long" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE=$2
  READLINE_POINT=${#READLINE_LINE}
  __lmline_explain_widget >/tmp/lmline-widget-explain-long.out 2>/tmp/lmline-widget-explain-long.err
  grep -q "\\[lm\\] command: printf" /tmp/lmline-widget-explain-long.err
  grep -q "line-bytes=.*${#READLINE_LINE}" /tmp/lmline-widget-explain-long.err
' _ "$repo_dir" "$long_explain_cmd" || fail "bash explain long line"
cli_explain_out=$(LMLINE_CONFIG_DIR="$widget_tmp/config-explain-cli" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" "$repo_dir/lmline/lmline" explain "echo hi")
grep -q "\\[lm\\] command: echo hi" <<<"$cli_explain_out" || fail "cli explain command"
grep -q "\\[lm\\] risk=low" <<<"$cli_explain_out" || fail "cli explain risk"
grep -q "\\[lm\\] command summary:" <<<"$cli_explain_out" || fail "cli explain command summary"
grep -q '^echo is' <<<"$cli_explain_out" || fail "cli explain type summary"
grep -q "\\[lm\\] model explanation:" <<<"$cli_explain_out" || fail "cli explain heading"
grep -q "\\[lm\\] m=explain-model; tok=50/16/66" <<<"$cli_explain_out" || fail "cli explain metadata"
grep -q "explained command" <<<"$cli_explain_out" || fail "cli explain model"
! grep -q '^$' <<<"$cli_explain_out" || fail "cli explain blank lines"
cli_long_explain_out=$(LMLINE_CONFIG_DIR="$widget_tmp/config-explain-cli-long" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" "$repo_dir/lmline/lmline" explain "$long_explain_cmd")
grep -q "line-bytes=.*${#long_explain_cmd}" <<<"$cli_long_explain_out" || fail "cli explain long line"
cat >"$widget_tmp/engine-explain-long-response" <<'EOF'
#!/usr/bin/env bash
while (($#)); do shift; done
printf 'x%.0s' {1..2000}
EOF
chmod +x "$widget_tmp/engine-explain-long-response"
cli_truncated_explain_out=$(LMLINE_EXPLAIN_MAX_OUTPUT_BYTES=1000 LMLINE_CONFIG_DIR="$widget_tmp/config-explain-truncated" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain-long-response" "$repo_dir/lmline/lmline" explain "echo hi")
grep -q "explanation-truncated .*max_bytes=1000" <<<"$cli_truncated_explain_out" || fail "cli explain truncation marker"
cli_pipeline_explain_out=$(LMLINE_CONFIG_DIR="$widget_tmp/config-explain-pipeline" LMLINE_PS0="[lm] " LMLINE_ENGINE="$widget_tmp/engine-explain" "$repo_dir/lmline/lmline" explain "yes '' | nl -b a -v 0 | head -n 31 | xargs -I @ date -d '20201201 +@days' +'%Y%m%d' | factor | awk 'NF==2&&\$0=\$2'")
grep -q '^date is ' <<<"$cli_pipeline_explain_out" || fail "cli explain covers xargs command"
grep -q '^awk is ' <<<"$cli_pipeline_explain_out" || fail "cli explain covers long pipeline"
LMLINE_CONFIG_DIR="$widget_tmp/config" LMLINE_ASYNC=0 LMLINE_ENGINE="$widget_tmp/engine" LMLINE_HISTORY_DIR="$widget_tmp/history" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  LMLINE_SELECTOR=definitely-not-a-selector
  READLINE_LINE=""
  READLINE_POINT=0
  __lmline_rewrite_widget >/tmp/lmline-widget-rewrite-empty.out 2>/tmp/lmline-widget-rewrite-empty.err
  [[ "$READLINE_LINE" == "" ]]
  READLINE_LINE="echo old"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_rewrite_widget >/tmp/lmline-widget-rewrite.out 2>/tmp/lmline-widget-rewrite.err
  [[ "$READLINE_LINE" == "echo one" ]]
  grep -q "selector unavailable" /tmp/lmline-widget-rewrite.err
  __lmline_next_widget
  [[ "$READLINE_LINE" == "echo two" ]]
  __lmline_next_widget
  [[ "$READLINE_LINE" == "echo old" ]]
  __lmline_prev_widget
  [[ "$READLINE_LINE" == "echo two" ]]
' _ "$repo_dir" || fail "rewrite candidate cycling"
cat >"$widget_tmp/engine-async" <<'EOF'
#!/usr/bin/env bash
sleep 0.3
printf 'lmline-candidate: low\tno matching risk rule\t-\techo one\nlmline-candidate: low\tno matching risk rule\t-\techo two\n'
EOF
chmod +x "$widget_tmp/engine-async"
LMLINE_CONFIG_DIR="$widget_tmp/config" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-async" LMLINE_HISTORY_DIR="$widget_tmp/history" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# say one"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-async1.out 2>/tmp/lmline-widget-async1.err
  async_pid=$__LMLINE_ASYNC_PID
  [[ $async_pid -gt 0 && "$READLINE_LINE" == "# say one" ]]
  wait "$async_pid" || exit 1
  __lmline_generate_widget >/tmp/lmline-widget-async2.out 2>/tmp/lmline-widget-async2.err
  [[ "$READLINE_LINE" == "echo one" ]]
' _ "$repo_dir" || fail "async widget"
# Both generations block on explicit gates; cancellation must stop the first
# engine AND its child without releasing that gate or touching another job.
cat >"$widget_tmp/engine-cancel" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" == child ]]; then
  name=$2
  exec 3<>"$LMLINE_TEST_ASYNC_DIR/$name.gate"
  trap 'printf stopped >"$LMLINE_TEST_ASYNC_DIR/$name.child.stopped"; exit 143' TERM
  printf "%s\n" "$$" >"$LMLINE_TEST_ASYNC_DIR/$name.child.ready"
  IFS= read -r -t 20 -u 3 release
  printf finished >"$LMLINE_TEST_ASYNC_DIR/$name.child.finished"
  exit
fi
while (($#)); do
  case "$1" in
    --line-file) line_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
name=$(cat "$line_file")
name=${name#\# }
printf "%s\n" "${line_file%/*}" >"$LMLINE_TEST_ASYNC_DIR/$name.context-dir"
trap 'wait "$child" 2>/dev/null || true; printf stopped >"$LMLINE_TEST_ASYNC_DIR/$name.engine.stopped"; exit 143' TERM
bash "$0" child "$name" &
child=$!
printf "%s\n" "$$" >"$LMLINE_TEST_ASYNC_DIR/$name.engine.ready"
wait "$child"
printf finished >"$LMLINE_TEST_ASYNC_DIR/$name.engine.finished"
printf "lmline-candidate: low\t-\t-\techo %s\n" "$name"
EOF
chmod +x "$widget_tmp/engine-cancel"
mkdir "$widget_tmp/cancel"
mkfifo "$widget_tmp/cancel/first.gate" "$widget_tmp/cancel/second.gate" "$widget_tmp/cancel/unrelated.gate" "$widget_tmp/cancel/timeout.gate"
LMLINE_TEST_ASYNC_DIR="$widget_tmp/cancel" LMLINE_CONFIG_DIR="$widget_tmp/config-clean" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-cancel" bash --norc -e -i -c '
    source "$1/lmline/init.bash"
    set -m
    wait_for_file() {
      local i
      for i in {1..200}; do
        [[ ! -s "$1" ]] || return 0
        sleep 0.05
      done
      return 1
    }
    cleanup_probe() {
      # Release blocked fixtures even if an assertion fails on an unfixed build.
      ( exec 3<>"$LMLINE_TEST_ASYNC_DIR/first.gate"; printf "release\n" >&3 )
      ( exec 3<>"$LMLINE_TEST_ASYNC_DIR/second.gate"; printf "release\n" >&3 )
      ( exec 3<>"$LMLINE_TEST_ASYNC_DIR/timeout.gate"; printf "release\n" >&3 )
      if [[ -n "${unrelated:-}" ]]; then
        kill "$unrelated" 2>/dev/null || true
        wait "$unrelated" 2>/dev/null || true
      fi
    }
    trap cleanup_probe EXIT
    bash "$LMLINE_ENGINE" child unrelated &
    unrelated=$!
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/unrelated.child.ready"
    READLINE_LINE="# first"
    READLINE_POINT=${#READLINE_LINE}
    __lmline_generate_widget >/dev/null 2>&1
    old_file=$__LMLINE_ASYNC_FILE
    old_pid=$__LMLINE_ASYNC_PID
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/first.engine.ready"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/first.child.ready"
    READLINE_LINE="# second"
    READLINE_POINT=${#READLINE_LINE}
    __lmline_generate_widget >/dev/null 2>&1
    [[ "$old_file" != "$__LMLINE_ASYNC_FILE" ]]
    [[ "$old_pid" != "$__LMLINE_ASYNC_PID" ]]
    [[ "$READLINE_LINE" == "# second" ]]
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/first.engine.stopped"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/first.child.stopped"
    ! kill -0 "$old_pid" 2>/dev/null
    ! kill -0 "$(cat "$LMLINE_TEST_ASYNC_DIR/first.engine.ready")" 2>/dev/null
    ! kill -0 "$(cat "$LMLINE_TEST_ASYNC_DIR/first.child.ready")" 2>/dev/null
    [[ ! -d "$(cat "$LMLINE_TEST_ASYNC_DIR/first.context-dir")" ]]
    [[ ! -e "$LMLINE_TEST_ASYNC_DIR/first.engine.finished" ]]
    [[ ! -e "$LMLINE_TEST_ASYNC_DIR/first.child.finished" ]]
    [[ ! -e "$old_file" && ! -e "$old_file.status" && ! -e "$old_file.status.err" ]]
    kill -0 "$unrelated"
    [[ ! -e "$LMLINE_TEST_ASYNC_DIR/unrelated.child.stopped" ]]
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/second.engine.ready"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/second.child.ready"
    printf "release\n" >"$LMLINE_TEST_ASYNC_DIR/second.gate"
    wait "$__LMLINE_ASYNC_PID"
    __lmline_generate_widget >/dev/null 2>&1
    [[ "$READLINE_LINE" == "echo second" ]]
    [[ -s "$LMLINE_TEST_ASYNC_DIR/second.engine.finished" ]]
    [[ -s "$LMLINE_TEST_ASYNC_DIR/second.child.finished" ]]
    [[ ! -e "$old_file" && ! -e "$old_file.status" ]]
    # Timeout uses the same cancellation path, not a supervisor-only kill.
    READLINE_LINE="# timeout"
    READLINE_POINT=${#READLINE_LINE}
    __lmline_generate_widget >/dev/null 2>&1
    timeout_file=$__LMLINE_ASYNC_FILE
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.engine.ready"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.child.ready"
    __LMLINE_ASYNC_STARTED=1
    __lmline_generate_widget >/dev/null 2>&1
    [[ "$READLINE_LINE" == "# timeout" && $__LMLINE_ASYNC_PID == 0 ]]
    [[ $- == *m* ]]
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.engine.stopped"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.child.stopped"
    ! kill -0 "$(cat "$LMLINE_TEST_ASYNC_DIR/timeout.engine.ready")" 2>/dev/null
    ! kill -0 "$(cat "$LMLINE_TEST_ASYNC_DIR/timeout.child.ready")" 2>/dev/null
    [[ ! -e "$timeout_file" && ! -e "$timeout_file.status" && ! -e "$timeout_file.status.err" ]]
    [[ ! -d "$(cat "$LMLINE_TEST_ASYNC_DIR/timeout.context-dir")" ]]
    kill -0 "$unrelated"
' _ "$repo_dir" || fail "async cleanup"
mkdir "$widget_tmp/cursor"
mkfifo "$widget_tmp/cursor/point-0.gate" "$widget_tmp/cursor/point-3.gate"
cat >"$widget_tmp/engine-cursor" <<'EOF'
#!/usr/bin/env bash
set -eu
point=0
while (($#)); do case "$1" in --point) point=$2; shift 2;; *) shift;; esac; done
stop_file=$LMLINE_TEST_CURSOR_DIR/point-$point.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf '%s\n' "$point" >"$LMLINE_TEST_CURSOR_DIR/point-$point.ready"
exec 3<>"$LMLINE_TEST_CURSOR_DIR/point-$point.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_CURSOR_DIR/point-$point.finished"
printf 'lmline-candidate: low\t-\t-\techo point-%s\n' "$point"
EOF
chmod +x "$widget_tmp/engine-cursor"
LMLINE_TEST_CURSOR_DIR="$widget_tmp/cursor" LMLINE_CONFIG_DIR="$widget_tmp/config-cursor" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-cursor" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  cleanup_cursor_probe() {
    for point in 0 3; do
      ( exec 3<>"$LMLINE_TEST_CURSOR_DIR/point-$point.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    for pid in "${first_pid:-}" "${second_pid:-}"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_cursor_probe EXIT
  READLINE_LINE="echo cursor"
  READLINE_POINT=0
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_CURSOR_DIR/point-0.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_CURSOR_DIR/point-0.ready" ]]
  READLINE_POINT=3
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$second_pid" != "$first_pid" ]]
  [[ "$READLINE_LINE" == "echo cursor" ]]
  [[ -s "$LMLINE_TEST_CURSOR_DIR/point-0.stopped" ]]
  [[ ! -e "$LMLINE_TEST_CURSOR_DIR/point-0.finished" ]]
  ! kill -0 "$first_pid" 2>/dev/null
  for i in {1..200}; do [[ -s "$LMLINE_TEST_CURSOR_DIR/point-3.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_CURSOR_DIR/point-3.ready" ]]
  printf "release\n" >"$LMLINE_TEST_CURSOR_DIR/point-3.gate"
  wait "$second_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo point-3" ]]
  [[ -s "$LMLINE_TEST_CURSOR_DIR/point-3.finished" ]]
' _ "$repo_dir" || fail "async cursor identity"
mkdir "$widget_tmp/settings-change"
mkdir "$widget_tmp/settings-change/config"
printf 'export LMLINE_CANDIDATE_COUNT=1\n' >"$widget_tmp/settings-change/config/settings.bash"
mkfifo "$widget_tmp/settings-change/count-1.gate" "$widget_tmp/settings-change/count-2.gate" "$widget_tmp/settings-change/count-3.gate"
cat >"$widget_tmp/engine-settings" <<'EOF'
#!/usr/bin/env bash
set -eu
n=0
while (($#)); do case "$1" in --n) n=$2; shift 2;; *) shift;; esac; done
stop_file=$LMLINE_TEST_SETTINGS_DIR/count-$n.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf ready >"$LMLINE_TEST_SETTINGS_DIR/count-$n.ready"
exec 3<>"$LMLINE_TEST_SETTINGS_DIR/count-$n.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_SETTINGS_DIR/count-$n.finished"
printf 'lmline-candidate: low\t-\t-\techo count-%s\n' "$n"
EOF
chmod +x "$widget_tmp/engine-settings"
LMLINE_TEST_SETTINGS_DIR="$widget_tmp/settings-change" LMLINE_CONFIG_DIR="$widget_tmp/settings-change/config" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-settings" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  cleanup_settings_probe() {
    for n in 1 2 3; do
      ( exec 3<>"$LMLINE_TEST_SETTINGS_DIR/count-$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    for pid in "${first_pid:-}" "${second_pid:-}" "${third_pid:-}"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_settings_probe EXIT
  READLINE_LINE="# count"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-1.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-1.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first_pid" ]]
  LMLINE_CANDIDATE_COUNT=2
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$LMLINE_CANDIDATE_COUNT" == 2 && "$second_pid" != "$first_pid" ]]
  [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-1.stopped" ]]
  [[ ! -e "$LMLINE_TEST_SETTINGS_DIR/count-1.finished" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-2.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-2.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$second_pid" ]]
  printf "export LMLINE_CANDIDATE_COUNT=3\n" >"$LMLINE_CONFIG_DIR/settings.bash"
  __lmline_generate_widget >/dev/null 2>&1
  third_pid=$__LMLINE_ASYNC_PID
  [[ "$LMLINE_CANDIDATE_COUNT" == 3 && "$third_pid" != "$second_pid" ]]
  [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-2.stopped" ]]
  [[ ! -e "$LMLINE_TEST_SETTINGS_DIR/count-2.finished" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-3.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-3.ready" ]]
  printf "release\n" >"$LMLINE_TEST_SETTINGS_DIR/count-3.gate"
  wait "$third_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo count-3" ]]
  [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-3.finished" ]]
' _ "$repo_dir" || fail "async candidate-count identity"
mkdir "$widget_tmp/model-change"
mkfifo "$widget_tmp/model-change/model-one.gate" "$widget_tmp/model-change/model-two.gate"
cat >"$widget_tmp/engine-model" <<'EOF'
#!/usr/bin/env bash
set -eu
model=$LMLINE_MODEL
stop_file=$LMLINE_TEST_MODEL_DIR/$model.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf ready >"$LMLINE_TEST_MODEL_DIR/$model.ready"
exec 3<>"$LMLINE_TEST_MODEL_DIR/$model.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_MODEL_DIR/$model.finished"
printf 'lmline-candidate: low\t-\t-\techo from-%s\n' "$model"
EOF
chmod +x "$widget_tmp/engine-model"
LMLINE_TEST_MODEL_DIR="$widget_tmp/model-change" LMLINE_CONFIG_DIR="$widget_tmp/config-model" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-model" LMLINE_MODEL=model-one bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  # Framing distinguishes embedded newlines, empty/unset values, and settings
  # that the engine actually inherits; overwritten name transports are ignored.
  export LMLINE_TEST_A="$(printf "one\nLMLINE_TEST_B=two")"
  key_a=$(__lmline_async_settings_key)
  export LMLINE_TEST_A=one LMLINE_TEST_B=two
  key_b=$(__lmline_async_settings_key)
  [[ "$key_a" != "$key_b" && "$key_a" != *one* ]]
  LMLINE_TEST_B=
  key_empty=$(__lmline_async_settings_key)
  unset LMLINE_TEST_B
  [[ "$key_empty" != "$(__lmline_async_settings_key)" ]]
  export LMLINE_SHELL_FUNCTIONS=ignored LMLINE_EXPORTED_FUNCTIONS=ignored
  key_a=$(__lmline_async_settings_key)
  LMLINE_SHELL_FUNCTIONS=changed LMLINE_EXPORTED_FUNCTIONS=changed
  [[ "$key_a" == "$(__lmline_async_settings_key)" ]]
  unset LMLINE_TEST_A LMLINE_SHELL_FUNCTIONS LMLINE_EXPORTED_FUNCTIONS
  LMLINE_TEST_UNEXPORTED=one
  key_a=$(__lmline_async_settings_key)
  LMLINE_TEST_UNEXPORTED=two
  [[ "$key_a" == "$(__lmline_async_settings_key)" ]]
  unset LMLINE_TEST_UNEXPORTED

  cleanup_model_probe() {
    for model in model-one model-two; do
      ( exec 3<>"$LMLINE_TEST_MODEL_DIR/$model.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    for pid in "${first_pid:-}" "${second_pid:-}"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_model_probe EXIT
  READLINE_LINE="# model"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_MODEL_DIR/model-one.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_MODEL_DIR/model-one.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first_pid" ]]
  LMLINE_MODEL=model-two
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$second_pid" != "$first_pid" ]]
  [[ -s "$LMLINE_TEST_MODEL_DIR/model-one.stopped" && ! -e "$LMLINE_TEST_MODEL_DIR/model-one.finished" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_MODEL_DIR/model-two.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_MODEL_DIR/model-two.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$second_pid" ]]
  printf "release\n" >"$LMLINE_TEST_MODEL_DIR/model-two.gate"
  wait "$second_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo from-model-two" && -s "$LMLINE_TEST_MODEL_DIR/model-two.finished" ]]
' _ "$repo_dir" || fail "bash async live model identity"
mkdir "$widget_tmp/functions-change"
mkfifo "$widget_tmp/functions-change/first.gate" "$widget_tmp/functions-change/second.gate"
cat >"$widget_tmp/engine-functions" <<'EOF'
#!/usr/bin/env bash
set -eu
if printf '%s\n' "${LMLINE_SHELL_FUNCTIONS-}" | grep -Fxq 'available_helper'; then
  name=second
else
  name=first
fi
if [[ "${LMLINE_SHELL_FUNCTIONS-}" == *body-marker* ]]; then exit 97; fi
stop_file=$LMLINE_TEST_FUNCTIONS_DIR/$name.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf ready >"$LMLINE_TEST_FUNCTIONS_DIR/$name.ready"
exec 3<>"$LMLINE_TEST_FUNCTIONS_DIR/$name.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_FUNCTIONS_DIR/$name.finished"
if [[ "$name" == second ]]; then
  printf 'lmline-candidate: low\t-\t-\techo has-helper\n'
else
  printf 'lmline-candidate: low\t-\t-\techo no-helper\n'
fi
EOF
chmod +x "$widget_tmp/engine-functions"
LMLINE_TEST_FUNCTIONS_DIR="$widget_tmp/functions-change" LMLINE_CONFIG_DIR="$widget_tmp/config-functions" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-functions" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  cleanup_functions_probe() {
    for name in first second; do
      ( exec 3<>"$LMLINE_TEST_FUNCTIONS_DIR/$name.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    for pid in "${first_pid:-}" "${second_pid:-}"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_functions_probe EXIT
  READLINE_LINE="# helper"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  first_file=$__LMLINE_ASYNC_FILE
  for i in {1..200}; do [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first_pid" ]]
  [[ "$__LMLINE_ASYNC_FILE" == "$first_file" ]]
  available_helper() { printf "body-marker\n" >>"$LMLINE_TEST_FUNCTIONS_DIR/body-ran"; }
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$second_pid" != "$first_pid" ]]
  [[ "$__LMLINE_ASYNC_FILE" != "$first_file" ]]
  [[ "$READLINE_LINE" == "# helper" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.stopped" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.stopped" ]]
  [[ ! -e "$LMLINE_TEST_FUNCTIONS_DIR/first.finished" ]]
  ! kill -0 "$first_pid" 2>/dev/null
  [[ ! -e "$first_file" && ! -e "$first_file.status" && ! -e "$first_file.status.err" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/second.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/second.ready" ]]
  printf "release\n" >"$LMLINE_TEST_FUNCTIONS_DIR/second.gate"
  wait "$second_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo has-helper" ]]
  [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/second.finished" ]]
  [[ ! -e "$LMLINE_TEST_FUNCTIONS_DIR/body-ran" ]]
' _ "$repo_dir" || fail "async function identity"
printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: synthetic async failure\\n" >&2\nexit 1\n' >"$widget_tmp/engine-fail"
chmod +x "$widget_tmp/engine-fail"
LMLINE_CONFIG_DIR="$widget_tmp/config-async-fail" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-fail" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="# fail"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/tmp/lmline-widget-fail1.out 2>/tmp/lmline-widget-fail1.err
  async_pid=$__LMLINE_ASYNC_PID
  [[ $async_pid -gt 0 ]]
  wait "$async_pid" || exit 1
  __lmline_generate_widget >/tmp/lmline-widget-fail2.out 2>/tmp/lmline-widget-fail2.err
  grep -q "synthetic async failure" /tmp/lmline-widget-fail2.err
' _ "$repo_dir" || fail "async failure hint"
rm -rf "$widget_tmp"
ok "widgets"
