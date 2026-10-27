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
for cmd in bash sort cksum cut awk; do ln -s "$(command -v "$cmd")" "$widget_tmp/hash-bin/$cmd"; done
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
    frontend=$(__lmline_async_frontend_key generate)
    [[ "$frontend" =~ ^[0-9]+$ && "$frontend" == "$(__lmline_async_frontend_key generate)" ]]
  )
  # Hash framing distinguishes unset, empty, and trailing newlines.
  (
    saved_path=$PATH
    __lmline_hash_stdin() { PATH=$saved_path command cksum; }
    unset PATH; unset_key=$(__lmline_path_key)
    PATH=; empty_key=$(__lmline_path_key)
    PATH="value"; value_key=$(__lmline_path_key)
    PATH=$'"'"'value\n'"'"'; newline_key=$(__lmline_path_key)
    [[ "$unset_key" != "$empty_key" && "$value_key" != "$newline_key" ]]
  )
  ( export PATH="$2/fail-hash-bin"; ! __lmline_async_settings_key >/dev/null )
  __lmline_async_function_names_key() { printf names; }
  __lmline_hint() { :; }
  __lmline_async_cleanup() { :; }
  __lmline_async_start() { rm -f "$4"; __LMLINE_ASYNC_KEY=$5; __LMLINE_ASYNC_PID=$$; starts=$((starts + 1)); }
  starts=0
  __lmline_generate_async_widget input generate 0
  [[ $starts == 1 && -n "$__LMLINE_ASYNC_KEY" ]]
  (
    __lmline_request_key() { printf partial; return 1; }
    __lmline_generate_async_widget input generate 0
    [[ $starts == 2 && -z "$__LMLINE_ASYNC_KEY" ]]
    __lmline_generate_async_widget input generate 0
    [[ $starts == 3 && -z "$__LMLINE_ASYNC_KEY" ]]
  )
  (
    LMLINE_INCLUDE_CWD_CONTEXT=1
    pwd() { return 1; }
    failed=$(__lmline_request_key generate input) && exit 1
    [[ -z "$failed" ]]
    LMLINE_INCLUDE_CWD_CONTEXT=0
    [[ -n "$(__lmline_request_key generate input)" ]]
  )
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
# Project marker bytes at the same path are part of pending identity.
mkdir "$widget_tmp/markers" "$widget_tmp/markers/rules" "$widget_tmp/markers/defaults"
mkdir "$widget_tmp/markers/privacy-bin"
cat >"$widget_tmp/markers/privacy-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if (($#)) || env | grep -Eq '^(LMLINE_CONFIG_DIR|LMLINE_USER_RULES_DIR|LMLINE_DEFAULTS_DIR|LMLINE_PROJECT_MARKERS_FILE|BASH_FUNC_lmline_marker_privacy%%)='; then
  printf leaked >"$LMLINE_TEST_MARKERS_DIR/leak"
fi
printf checked >"$LMLINE_TEST_MARKERS_DIR/checked"
exec cksum
EOF
chmod +x "$widget_tmp/markers/privacy-bin/sha256sum"
touch "$widget_tmp/markers/one.marker" "$widget_tmp/markers/two.marker"
printf 'one\tone.marker\n' >"$widget_tmp/markers/list"
printf 'two\ttwo.marker\n' >"$widget_tmp/markers/rules/project_markers.tsv"
printf 'default\tone.marker\n' >"$widget_tmp/markers/defaults/project_markers.tsv"
mkfifo "$widget_tmp/markers/one.gate" "$widget_tmp/markers/two.gate" "$widget_tmp/markers/absent.gate"
cat >"$widget_tmp/engine-markers" <<'EOF'
#!/usr/bin/env bash
set -eu
while (($#)); do case "$1" in --context-file) context=$2; shift 2;; *) shift;; esac; done
if grep -qx one "$context"; then name=one; elif grep -qx two "$context"; then name=two; else name=absent; fi
trap 'printf stopped >"$LMLINE_TEST_MARKERS_DIR/$name.stopped"; exit 143' TERM
printf ready >"$LMLINE_TEST_MARKERS_DIR/$name.ready"
exec 3<>"$LMLINE_TEST_MARKERS_DIR/$name.gate"
IFS= read -r -t 20 -u 3 release
printf 'lmline-candidate: low\t-\t-\techo %s\n' "$name"
EOF
chmod +x "$widget_tmp/engine-markers"
LMLINE_TEST_MARKERS_DIR="$widget_tmp/markers" LMLINE_CONFIG_DIR="$widget_tmp/config-markers" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-markers" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  cd "$LMLINE_TEST_MARKERS_DIR"
  trap '\''for n in one two absent; do ( exec 3<>"$LMLINE_TEST_MARKERS_DIR/$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done; __lmline_async_cleanup'\'' EXIT
  LMLINE_USER_RULES_DIR=$PWD/rules LMLINE_DEFAULTS_DIR=$PWD/defaults LMLINE_PROJECT_MARKERS_FILE=$PWD/list
  export LMLINE_PROJECT_MARKERS_FILE
  lmline_marker_privacy() { : private_body; }
  export -f lmline_marker_privacy
  ( PATH="$PWD/privacy-bin:$PATH"; __lmline_project_markers_key >/dev/null )
  [[ -s checked && ! -e leak ]]
  unset -f lmline_marker_privacy
  key=$(__lmline_project_markers_key)
  [[ "$key" != *one* && "$key" != *"$PWD"* ]]
  unset LMLINE_PROJECT_MARKERS_FILE
  user_key=$(__lmline_project_markers_key)
  [[ "$key" != "$user_key" ]]
  rm rules/project_markers.tsv
  [[ "$user_key" != "$(__lmline_project_markers_key)" ]]
  LMLINE_DEFAULTS_DIR=$1/lmline/defaults LMLINE_PROJECT_MARKERS_FILE=$PWD/list
  ( __lmline_resolve_data_file() { return 1; }; ! __lmline_project_markers_key >/dev/null )
  ( __lmline_hash_stdin() { return 1; }; ! __lmline_project_markers_key >/dev/null )
  ( __lmline_hash_stdin() { return 0; }; ! __lmline_project_markers_key >/dev/null )
  ( __lmline_project_markers_scan() { return 1; }; ! __lmline_project_markers_key >/dev/null )
  ( LMLINE_PROJECT_MARKERS_FILE=$PWD/missing; ! __lmline_project_markers_key >/dev/null )
  mkfifo fifo
  ( LMLINE_PROJECT_MARKERS_FILE=$PWD/fifo; ! __lmline_project_markers_key >/dev/null )
  ( LMLINE_INCLUDE_PROJECT_CONTEXT=off LMLINE_PROJECT_MARKERS_FILE=$PWD/missing
    __lmline_resolve_data_file() { return 1; }
    __lmline_hash_stdin() { return 1; }
    [[ "$(__lmline_project_markers_key)" == disabled ]]
  )
  READLINE_LINE="# markers"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s one.ready ]] && break; sleep 0.05; done
  [[ -s one.ready ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first" ]]
  printf "two\ttwo.marker\n" >list
  [[ "$key" != "$(__lmline_project_markers_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  second=$__LMLINE_ASYNC_PID
  [[ "$second" != "$first" && -s one.stopped && "$READLINE_LINE" == "# markers" ]]
  for i in {1..200}; do [[ -s two.ready ]] && break; sleep 0.05; done
  [[ -s two.ready ]]
  printf "release\n" >two.gate
  wait "$second"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo two" ]]
  # Change only marker presence while the absent-context request is pending.
  printf "one\tone.marker\n" >list
  rm one.marker one.ready one.stopped two.ready
  key=$(__lmline_project_markers_key)
  READLINE_LINE="# markers"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s absent.ready ]] && break; sleep 0.05; done
  [[ -s absent.ready ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first" ]]
  touch one.marker
  [[ "$key" != "$(__lmline_project_markers_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  second=$__LMLINE_ASYNC_PID
  [[ "$second" != "$first" && -s absent.stopped && "$READLINE_LINE" == "# markers" ]]
  ! kill -0 "$first" 2>/dev/null
  for i in {1..200}; do [[ -s one.ready ]] && break; sleep 0.05; done
  [[ -s one.ready ]]
  printf "release\n" >one.gate
  wait "$second"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo one" ]]
  # An unavailable identity cannot reuse a pending request.
  __lmline_project_markers_key() { return 1; }
  READLINE_LINE="# markers"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first=$__LMLINE_ASYNC_PID
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" != "$first" ]]
' _ "$repo_dir" || fail "bash project-marker content identity"
# Git root and branch, but not working-tree status, determine pending identity.
mkdir "$widget_tmp/git-probe" "$widget_tmp/git-probe/repo" "$widget_tmp/git-probe/privacy-bin"
cat >"$widget_tmp/git-probe/privacy-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if (($#)) || env | grep -Eq '^(__lmline_git_root|__lmline_git_branch|BASH_FUNC_lmline_git_privacy%%)='; then
  printf leaked >"$LMLINE_TEST_GIT_DIR/leak"
fi
printf checked >"$LMLINE_TEST_GIT_DIR/checked"
exec cksum
EOF
chmod +x "$widget_tmp/git-probe/privacy-bin/sha256sum"
git -C "$widget_tmp/git-probe/repo" init -q
git -C "$widget_tmp/git-probe/repo" symbolic-ref HEAD refs/heads/one
mkfifo "$widget_tmp/git-probe/one.gate" "$widget_tmp/git-probe/two.gate"
cat >"$widget_tmp/engine-git" <<'EOF'
#!/usr/bin/env bash
set -eu
while (($#)); do case "$1" in --context-file) context=$2; shift 2;; *) shift;; esac; done
if grep -qx '| branch=one' "$context"; then name=one; else grep -qx '| branch=two' "$context"; name=two; fi
trap 'printf stopped >"$LMLINE_TEST_GIT_DIR/$name.stopped"; exit 143' TERM
printf ready >"$LMLINE_TEST_GIT_DIR/$name.ready"
exec 3<>"$LMLINE_TEST_GIT_DIR/$name.gate"
IFS= read -r -t 20 -u 3 release
printf 'lmline-candidate: low\t-\t-\techo %s\n' "$name"
EOF
chmod +x "$widget_tmp/engine-git"
LMLINE_TEST_GIT_DIR="$widget_tmp/git-probe" LMLINE_CONFIG_DIR="$widget_tmp/config-git" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-git" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  cd "$LMLINE_TEST_GIT_DIR/repo"
  cleanup_git_probe() {
    for n in one two; do ( exec 3<>"$LMLINE_TEST_GIT_DIR/$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
    __lmline_async_cleanup
  }
  trap cleanup_git_probe EXIT
  ( LMLINE_INCLUDE_GIT_CONTEXT=off
    git() { printf called >"$LMLINE_TEST_GIT_DIR/git-called"; return 1; }
    [[ "$(__lmline_git_context_key)" == disabled && ! -e "$LMLINE_TEST_GIT_DIR/git-called" ]]
  )
  ( PATH=/nonexistent; [[ "$(__lmline_git_context_key)" == absent ]] )
  ( cd "$LMLINE_TEST_GIT_DIR"; [[ "$(__lmline_git_context_key)" == absent ]] )
  ( git() { case "$*" in "rev-parse --is-inside-work-tree") return 0;; *) return 1;; esac; }; ! __lmline_git_context_key >/dev/null )
  ( git() { case "$*" in "rev-parse --is-inside-work-tree") return 0;; "rev-parse --show-toplevel") printf root;; *) return 1;; esac; }; ! __lmline_git_context_key >/dev/null )
  ( __lmline_hash_stdin() { return 1; }; ! __lmline_git_context_key >/dev/null )
  ( git() { case "$*" in "rev-parse --is-inside-work-tree") return 0;; "rev-parse --show-toplevel") printf root;; "branch --show-current") return 0;; esac; }; [[ -n "$(__lmline_git_context_key)" ]] )
  ( git() { case "$*" in "rev-parse --is-inside-work-tree") return 1;; *) return 1;; esac; }; [[ "$(__lmline_git_context_key)" == absent ]] )
  ( __lmline_hash_stdin() { return 0; }; ! __lmline_git_context_key >/dev/null )
  ( git() { case "$*" in "rev-parse --is-inside-work-tree") return 0;; "rev-parse --show-toplevel") printf "%s" "$test_root";; "branch --show-current") printf "%s" "$test_branch";; esac; }
    test_root=a; test_branch=bc; framed=$(__lmline_git_context_key)
    test_root=b; test_branch=bc; [[ "$framed" != "$(__lmline_git_context_key)" ]]
    test_root=ab; test_branch=c; [[ "$framed" != "$(__lmline_git_context_key)" ]]
  )
  ( export __lmline_git_root=old __lmline_git_branch=old
    lmline_git_privacy() { :; }; export -f lmline_git_privacy
    PATH="$LMLINE_TEST_GIT_DIR/privacy-bin:$PATH"; __lmline_git_context_key >/dev/null
    [[ -s "$LMLINE_TEST_GIT_DIR/checked" && ! -e "$LMLINE_TEST_GIT_DIR/leak" ]]
  )
  key=$(__lmline_git_context_key)
  [[ "$key" != *one* && "$key" != *"$PWD"* ]]
  touch untracked
  [[ "$key" == "$(__lmline_git_context_key)" ]]
  READLINE_LINE="# git"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_GIT_DIR/one.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_GIT_DIR/one.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first" ]]
  git branch -m two
  [[ "$key" != "$(__lmline_git_context_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  second=$__LMLINE_ASYNC_PID
  [[ "$second" != "$first" && -s "$LMLINE_TEST_GIT_DIR/one.stopped" && "$READLINE_LINE" == "# git" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_GIT_DIR/two.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_GIT_DIR/two.ready" ]]
  printf "release\n" >"$LMLINE_TEST_GIT_DIR/two.gate"
  wait "$second"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo two" ]]
  __lmline_git_context_key() { return 1; }
  READLINE_LINE="# git"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first=$__LMLINE_ASYNC_PID
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" != "$first" ]]
' _ "$repo_dir" || fail "bash git context identity"

# Replacing a list at the same path invalidates both pending and ready work.
mkdir "$widget_tmp/suggested"
mkdir "$widget_tmp/suggested/privacy-bin"
cat >"$widget_tmp/suggested/privacy-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if (($#)) || env | grep -Eq '^(LMLINE_CONFIG_DIR|LMLINE_USER_RULES_DIR|LMLINE_DEFAULTS_DIR|LMLINE_SUGGESTED_COMMANDS_FILE|BASH_FUNC_lmline_privacy_probe%%)='; then
  printf leaked >"$LMLINE_TEST_SUGGESTED_DIR/leak"
fi
printf checked >"$LMLINE_TEST_SUGGESTED_DIR/checked"
exec cksum
EOF
chmod +x "$widget_tmp/suggested/privacy-bin/sha256sum"
mkfifo "$widget_tmp/suggested/printf.gate" "$widget_tmp/suggested/sleep.gate"
printf 'printf\n' >"$widget_tmp/suggested/list"
cat >"$widget_tmp/engine-suggested" <<'EOF'
#!/usr/bin/env bash
set -eu
while (($#)); do case "$1" in --context-file) context=$2; shift 2;; *) shift;; esac; done
if grep -qx printf "$context"; then command_name=printf; else grep -qx sleep "$context"; command_name=sleep; fi
trap 'printf stopped >"$LMLINE_TEST_SUGGESTED_DIR/$command_name.stopped"; exit 143' TERM
printf ready >"$LMLINE_TEST_SUGGESTED_DIR/$command_name.ready"
exec 3<>"$LMLINE_TEST_SUGGESTED_DIR/$command_name.gate"
IFS= read -r -t 20 -u 3 release
printf 'lmline-candidate: low\t-\t-\techo %s\n' "$command_name"
EOF
chmod +x "$widget_tmp/engine-suggested"
LMLINE_TEST_SUGGESTED_DIR="$widget_tmp/suggested" LMLINE_CONFIG_DIR="$widget_tmp/config-suggested" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-suggested" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/list
  export LMLINE_SUGGESTED_COMMANDS_FILE
  cleanup_suggested_probe() {
    for n in printf sleep; do ( exec 3<>"$LMLINE_TEST_SUGGESTED_DIR/$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
    __lmline_async_cleanup
  }
  trap cleanup_suggested_probe EXIT
  lmline_privacy_probe() { : private_function_body; }
  export -f lmline_privacy_probe
  ( PATH="$LMLINE_TEST_SUGGESTED_DIR/privacy-bin:$PATH"; __lmline_suggested_commands_key >/dev/null )
  [[ -s "$LMLINE_TEST_SUGGESTED_DIR/checked" && ! -e "$LMLINE_TEST_SUGGESTED_DIR/leak" ]]
  unset -f lmline_privacy_probe
  ( __lmline_hash_stdin() { return 1; }; ! __lmline_path_key >/dev/null )
  ( __lmline_hash_stdin() { return 0; }; ! __lmline_path_key >/dev/null )
  key=$(__lmline_suggested_commands_key)
  [[ "$key" != *printf* && "$key" != *"$LMLINE_SUGGESTED_COMMANDS_FILE"* ]]
  mkfifo "$LMLINE_TEST_SUGGESTED_DIR/list-fifo"
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/list-fifo
  printf "find\n" >"$LMLINE_SUGGESTED_COMMANDS_FILE" & fifo_writer=$!
  if __lmline_suggested_commands_key >/dev/null 2>&1; then
    kill "$fifo_writer" 2>/dev/null || true
    wait "$fifo_writer" 2>/dev/null || true
    exit 1
  fi
  kill "$fifo_writer" 2>/dev/null || true
  wait "$fifo_writer" 2>/dev/null || true
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/list
  READLINE_LINE="# list"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]]
  # An unchanged PATH reuses pending work; a byte change cancels it.
  path_key=$(__lmline_path_key)
  [[ "$path_key" != *"$PATH"* ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first_pid" ]]
  rm -f "$LMLINE_TEST_SUGGESTED_DIR/printf.ready"
  export PATH="$LMLINE_TEST_SUGGESTED_DIR:$PATH"
  [[ "$path_key" != "$(__lmline_path_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  path_pid=$__LMLINE_ASYNC_PID
  [[ "$first_pid" != "$path_pid" && "$READLINE_LINE" == "# list" && -s "$LMLINE_TEST_SUGGESTED_DIR/printf.stopped" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]]
  first_pid=$path_pid
  printf "sleep \n" >"$LMLINE_SUGGESTED_COMMANDS_FILE"
  [[ "$key" != "$(__lmline_suggested_commands_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$first_pid" != "$second_pid" && "$READLINE_LINE" == "# list" && -s "$LMLINE_TEST_SUGGESTED_DIR/printf.stopped" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_SUGGESTED_DIR/sleep.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_SUGGESTED_DIR/sleep.ready" ]]
  printf "release\n" >"$LMLINE_TEST_SUGGESTED_DIR/sleep.gate"
  wait "$second_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo sleep" ]]
  READLINE_LINE="# list"; READLINE_POINT=${#READLINE_LINE}
  printf "printf\n" >"$LMLINE_SUGGESTED_COMMANDS_FILE"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" != "$second_pid" && "$READLINE_LINE" == "# list" ]]
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/missing
  ! __lmline_suggested_commands_key >/dev/null
  third_pid=$__LMLINE_ASYNC_PID
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" != "$third_pid" && "$READLINE_LINE" == "# list" ]]
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/list
  ( __lmline_hash_stdin() { return 1; }; ! __lmline_suggested_commands_key >/dev/null )
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/missing
  LMLINE_INCLUDE_SUGGESTED_COMMANDS=0
  [[ "$(__lmline_suggested_commands_key)" == disabled ]]
  # Failure or empty output from the PATH digest must never reuse pending work.
  __lmline_generate_widget >/dev/null 2>&1
  [[ -n "$__LMLINE_ASYNC_KEY" && "$__LMLINE_ASYNC_KEY" != function-context-unavailable ]]
  __lmline_path_key() { return 1; }
  failed_pid=$__LMLINE_ASYNC_PID
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" != "$failed_pid" && "$READLINE_LINE" == "# list" ]]
  __lmline_path_key() { return 0; }
  failed_pid=$__LMLINE_ASYNC_PID
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" != "$failed_pid" && "$READLINE_LINE" == "# list" ]]
' _ "$repo_dir" || fail "bash suggested-command content identity"
# Availability changes inside an existing PATH directory invalidate pending work.
mkdir "$widget_tmp/availability" "$widget_tmp/availability/bin"
printf 'lmline-availability-external\nlmline-availability-alias\n' >"$widget_tmp/availability/list"
for phase in absent external; do mkfifo "$widget_tmp/availability/$phase.gate"; done
cat >"$widget_tmp/engine-availability" <<'EOF'
#!/usr/bin/env bash
set -eu
while (($#)); do case "$1" in --context-file) context=$2; shift 2;; *) shift;; esac; done
phase=absent
if grep -qx lmline-availability-external "$context"; then phase=external; fi
grep -E '^lmline-availability-(external|alias)$' "$context" >"$LMLINE_TEST_AVAILABILITY_DIR/$phase.members" || true
trap 'printf stopped >"$LMLINE_TEST_AVAILABILITY_DIR/$phase.stopped"; exit 143' TERM
printf ready >"$LMLINE_TEST_AVAILABILITY_DIR/$phase.ready"
exec 3<>"$LMLINE_TEST_AVAILABILITY_DIR/$phase.gate"
IFS= read -r -t 20 -u 3 release
printf 'lmline-candidate: low\t-\t-\techo %s\n' "$phase"
EOF
chmod +x "$widget_tmp/engine-availability"
LMLINE_TEST_AVAILABILITY_DIR="$widget_tmp/availability" LMLINE_CONFIG_DIR="$widget_tmp/config-availability" LMLINE_ASYNC=1 LMLINE_ENGINE="$widget_tmp/engine-availability" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_AVAILABILITY_DIR/list
  export PATH="$LMLINE_TEST_AVAILABILITY_DIR/bin:$PATH"
  cleanup_availability_probe() {
    for phase in absent external; do ( exec 3<>"$LMLINE_TEST_AVAILABILITY_DIR/$phase.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
    __lmline_async_cleanup
  }
  trap cleanup_availability_probe EXIT
  initial_path=$PATH
  list_bytes=$(cksum <"$LMLINE_SUGGESTED_COMMANDS_FILE")
  key=$(__lmline_suggested_commands_key)
  [[ -n "$key" && "$key" != *lmline-availability* && "$key" != *"$LMLINE_SUGGESTED_COMMANDS_FILE"* ]]
  # A populated renderer cache must not influence the availability fingerprint.
  ( __LMLINE_SUGGESTED_COMMANDS_FILE_CACHE=$LMLINE_SUGGESTED_COMMANDS_FILE
    __LMLINE_SUGGESTED_COMMANDS_CACHE=lmline-availability-external
    [[ "$key" == "$(__lmline_suggested_commands_key)" ]] )
  ( __lmline_collect_suggested_commands() { return 1; }; ! __lmline_suggested_commands_key >/dev/null )
  ( __lmline_hash_stdin() { return 0; }; ! __lmline_suggested_commands_key >/dev/null )
  # The file digest can succeed while the membership digest is empty.
  ( __lmline_hash_stdin() {
      local first second
      IFS= read -r first || :
      if IFS= read -r second; then printf file-digest; fi
    }; ! __lmline_suggested_commands_key >/dev/null )
  READLINE_LINE="# availability"; READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first=$__LMLINE_ASYNC_PID; first_key=$__LMLINE_ASYNC_KEY
  for i in {1..200}; do [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.ready" && ! -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.members" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first" ]]
  printf "#!/bin/sh\nexit 0\n" >"$LMLINE_TEST_AVAILABILITY_DIR/bin/lmline-availability-external"
  chmod +x "$LMLINE_TEST_AVAILABILITY_DIR/bin/lmline-availability-external"
  [[ "$PATH" == "$initial_path" && "$(cksum <"$LMLINE_SUGGESTED_COMMANDS_FILE")" == "$list_bytes" ]]
  [[ "$key" != "$(__lmline_suggested_commands_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  second=$__LMLINE_ASYNC_PID
  [[ "$second" != "$first" && "$__LMLINE_ASYNC_KEY" != "$first_key" && "$READLINE_LINE" == "# availability" && -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.stopped" ]]
  for i in {1..200}; do [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/external.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/external.ready" ]]
  [[ "$(cat "$LMLINE_TEST_AVAILABILITY_DIR/external.members")" == lmline-availability-external ]]
  # Caller aliases remain visible to foreground context rendering, but do not
  # invalidate an async key whose background worker cannot see them.
  key=$(__lmline_suggested_commands_key)
  first=$second; first_key=$__LMLINE_ASYNC_KEY
  alias lmline-availability-alias=true
  alias lmline-availability-alias >/dev/null && shopt -q expand_aliases
  ( __lmline_context_file "$LMLINE_TEST_AVAILABILITY_DIR/foreground.context" "# availability" generate )
  grep -qx lmline-availability-alias "$LMLINE_TEST_AVAILABILITY_DIR/foreground.context"
  [[ "$PATH" == "$initial_path" && "$(cksum <"$LMLINE_SUGGESTED_COMMANDS_FILE")" == "$list_bytes" ]]
  [[ "$key" == "$(__lmline_suggested_commands_key)" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first" && "$__LMLINE_ASYNC_KEY" == "$first_key" && "$READLINE_LINE" == "# availability" ]]
  [[ ! -s "$LMLINE_TEST_AVAILABILITY_DIR/external.stopped" ]]
  [[ "$(cat "$LMLINE_TEST_AVAILABILITY_DIR/external.members")" == lmline-availability-external ]]
  printf "release\n" >"$LMLINE_TEST_AVAILABILITY_DIR/external.gate"
  wait "$first"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo external" ]]
' _ "$repo_dir" || fail "bash suggested-command availability identity"
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
  export -n LMLINE_INCLUDE_SHELL_CONTEXT LMLINE_USER_RULES_DIR
  LMLINE_INCLUDE_SHELL_CONTEXT=0
  LMLINE_USER_RULES_DIR=context-path-marker
  context_key=$(__lmline_context_settings_key)
  [[ -n "$context_key" && "$context_key" != *context-path-marker* ]]
  LMLINE_INCLUDE_SHELL_CONTEXT=1
  [[ "$context_key" != "$(__lmline_context_settings_key)" ]]
  LMLINE_TEST_UNEXPORTED=one
  context_key=$(__lmline_context_settings_key)
  LMLINE_TEST_UNEXPORTED=two
  [[ "$context_key" == "$(__lmline_context_settings_key)" ]]
  unset LMLINE_TEST_UNEXPORTED
  ( __lmline_hash_stdin() { return 1; }; ! __lmline_context_settings_key >/dev/null )

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
# A rename changes physical context without changing the shell logical PWD.
mkdir "$widget_tmp/cwd-change" "$widget_tmp/cwd-change/before"
mkfifo "$widget_tmp/cwd-change/before.gate" "$widget_tmp/cwd-change/after.gate" "$widget_tmp/cwd-change/off.gate"
cat >"$widget_tmp/engine-cwd" <<'EOF'
#!/usr/bin/env bash
set -eu
context=
while (($#)); do
  case $1 in --context-file) context=$2; shift 2 ;; *) shift ;; esac
done
if ! grep -q '^## cwd$' "$context"; then name=off
elif grep -Fxq "$LMLINE_TEST_CWD_DIR/before" "$context"; then name=before
elif grep -Fxq "$LMLINE_TEST_CWD_DIR/after" "$context"; then name=after
else exit 98
fi
trap 'printf stopped >"$LMLINE_TEST_CWD_DIR/$name.stopped"; exit 143' TERM
exec 3<>"$LMLINE_TEST_CWD_DIR/$name.gate"
printf ready >"$LMLINE_TEST_CWD_DIR/$name.ready"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_CWD_DIR/$name.finished"
printf 'lmline-candidate: low\t-\t-\techo cwd-%s\n' "$name"
EOF
chmod +x "$widget_tmp/engine-cwd"
cwd_change_dir=$(cd "$widget_tmp/cwd-change" && pwd -P)
LMLINE_TEST_CWD_DIR="$cwd_change_dir" LMLINE_CONFIG_DIR="$widget_tmp/config-cwd" LMLINE_ASYNC=1 LMLINE_STATUS_MODE=silent LMLINE_ENGINE="$widget_tmp/engine-cwd" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  LMLINE_INCLUDE_GIT_CONTEXT=0
  LMLINE_INCLUDE_PROJECT_CONTEXT=0
  cleanup_cwd_probe() {
    for name in before after off; do
      ( exec 3<>"$LMLINE_TEST_CWD_DIR/$name.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    __lmline_async_cleanup
  }
  trap cleanup_cwd_probe EXIT
  cd "$LMLINE_TEST_CWD_DIR/before"
  for enabled in 0 1; do
    export -n LMLINE_INCLUDE_CWD_CONTEXT
    LMLINE_INCLUDE_CWD_CONTEXT=$enabled
    logical=$PWD
    physical=$(pwd -P)
    key=$(__lmline_request_key generate "# cwd")
    [[ -n "$key" && "$key" != *"$logical"* && "$key" != *"$physical"* ]]
    READLINE_LINE="# cwd"; READLINE_POINT=${#READLINE_LINE}
    __lmline_generate_widget >/dev/null 2>&1
    first_pid=$__LMLINE_ASYNC_PID
    name=off; [[ "$enabled" == 0 ]] || name=before
    for i in {1..200}; do [[ -s "$LMLINE_TEST_CWD_DIR/$name.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_CWD_DIR/$name.ready" ]]
    mv "$LMLINE_TEST_CWD_DIR/before" "$LMLINE_TEST_CWD_DIR/after"
    [[ "$PWD" == "$logical" && "$(pwd -P)" != "$physical" ]]
    if [[ "$enabled" == 1 ]]; then
      [[ "$key" != "$(__lmline_request_key generate "# cwd")" ]]
    else
      [[ "$key" == "$(__lmline_request_key generate "# cwd")" ]]
    fi
    __lmline_generate_widget >/dev/null 2>&1
    second_pid=$__LMLINE_ASYNC_PID
    [[ "$READLINE_LINE" == "# cwd" ]]
    if [[ "$enabled" == 1 ]]; then
      [[ "$second_pid" != "$first_pid" && -s "$LMLINE_TEST_CWD_DIR/before.stopped" ]]
      [[ ! -e "$LMLINE_TEST_CWD_DIR/before.finished" ]]
      ! kill -0 "$first_pid" 2>/dev/null
      name=after
    else
      [[ "$second_pid" == "$first_pid" ]]
    fi
    for i in {1..200}; do [[ -s "$LMLINE_TEST_CWD_DIR/$name.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_CWD_DIR/$name.ready" ]]
    printf "release\n" >"$LMLINE_TEST_CWD_DIR/$name.gate"
    wait "$second_pid"
    __lmline_generate_widget >/dev/null 2>&1
    [[ "$READLINE_LINE" == "echo cwd-$name" ]]
    mv "$LMLINE_TEST_CWD_DIR/after" "$LMLINE_TEST_CWD_DIR/before"
  done
' _ "$repo_dir" || fail "bash async physical cwd identity"
mkdir "$widget_tmp/context-change"
mkfifo "$widget_tmp/context-change/off.gate" "$widget_tmp/context-change/on.gate"
cat >"$widget_tmp/engine-context" <<'EOF'
#!/usr/bin/env bash
set -eu
context=
while (($#)); do
  case $1 in
    --context-file) context=$2; shift 2 ;;
    *) shift ;;
  esac
done
if grep -q '^## shell$' "$context"; then name=on; else name=off; fi
stop_file=$LMLINE_TEST_CONTEXT_DIR/$name.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf ready >"$LMLINE_TEST_CONTEXT_DIR/$name.ready"
exec 3<>"$LMLINE_TEST_CONTEXT_DIR/$name.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_CONTEXT_DIR/$name.finished"
printf 'lmline-candidate: low\t-\t-\techo shell-%s\n' "$name"
EOF
chmod +x "$widget_tmp/engine-context"
LMLINE_TEST_CONTEXT_DIR="$widget_tmp/context-change" LMLINE_CONFIG_DIR="$widget_tmp/config-context" LMLINE_ASYNC=1 LMLINE_STATUS_MODE=silent LMLINE_ENGINE="$widget_tmp/engine-context" bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  export -n LMLINE_INCLUDE_SHELL_CONTEXT
  LMLINE_INCLUDE_SHELL_CONTEXT=0
  cleanup_context_probe() {
    for name in off on; do
      ( exec 3<>"$LMLINE_TEST_CONTEXT_DIR/$name.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    for pid in "${first_pid:-}" "${second_pid:-}"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_context_probe EXIT
  READLINE_LINE="# context"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_CONTEXT_DIR/off.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_CONTEXT_DIR/off.ready" ]]
  LMLINE_INCLUDE_SHELL_CONTEXT=1
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$second_pid" != "$first_pid" ]]
  [[ -s "$LMLINE_TEST_CONTEXT_DIR/off.stopped" && ! -e "$LMLINE_TEST_CONTEXT_DIR/off.finished" ]]
  ! kill -0 "$first_pid" 2>/dev/null
  for i in {1..200}; do [[ -s "$LMLINE_TEST_CONTEXT_DIR/on.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_CONTEXT_DIR/on.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$second_pid" ]]
  printf "release\n" >"$LMLINE_TEST_CONTEXT_DIR/on.gate"
  wait "$second_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo shell-on" && -s "$LMLINE_TEST_CONTEXT_DIR/on.finished" ]]
  [[ ! -e "$LMLINE_TEST_CONTEXT_DIR/off.finished" ]]
' _ "$repo_dir" || fail "bash async shell-local context identity"
mkdir "$widget_tmp/engine-change"
mkfifo "$widget_tmp/engine-change/engine-one.gate" "$widget_tmp/engine-change/engine-two.gate"
cat >"$widget_tmp/engine-change/engine-one" <<'EOF'
#!/usr/bin/env bash
set -eu
name=${0##*/}
stop_file=$LMLINE_TEST_ENGINE_DIR/$name.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf ready >"$LMLINE_TEST_ENGINE_DIR/$name.ready"
exec 3<>"$LMLINE_TEST_ENGINE_DIR/$name.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_ENGINE_DIR/$name.finished"
printf 'lmline-candidate: low\t-\t-\techo from-%s\n' "$name"
EOF
cp "$widget_tmp/engine-change/engine-one" "$widget_tmp/engine-change/engine-two"
chmod +x "$widget_tmp/engine-change/engine-one" "$widget_tmp/engine-change/engine-two"
LMLINE_TEST_ENGINE_DIR="$widget_tmp/engine-change" LMLINE_CONFIG_DIR="$widget_tmp/config-engine-change" LMLINE_ASYNC=1 bash --norc -e -i -c '
  source "$1/lmline/init.bash"
  export -n LMLINE_ENGINE LMLINE_GENERATE_BACKEND LMLINE_REWRITE_BACKEND
  LMLINE_ENGINE=$LMLINE_TEST_ENGINE_DIR/engine-one
  LMLINE_GENERATE_BACKEND=engine LMLINE_REWRITE_BACKEND=engine
  key=$(__lmline_async_frontend_key generate)
  [[ "$key" != *"$LMLINE_ENGINE"* ]]
  LMLINE_GENERATE_BACKEND=copilot
  [[ "$key" != "$(__lmline_async_frontend_key generate)" ]]
  LMLINE_GENERATE_BACKEND=
  [[ "$key" == "$(__lmline_async_frontend_key generate)" ]]
  unset LMLINE_GENERATE_BACKEND
  [[ "$key" == "$(__lmline_async_frontend_key generate)" ]]
  LMLINE_REWRITE_BACKEND=copilot
  [[ "$key" == "$(__lmline_async_frontend_key generate)" ]]
  rewrite_key=$(__lmline_async_frontend_key rewrite)
  LMLINE_REWRITE_BACKEND=engine
  [[ "$rewrite_key" != "$(__lmline_async_frontend_key rewrite)" ]]
  ( __lmline_hash_stdin() { printf bad; return 1; }; ! __lmline_async_frontend_key generate >/dev/null )
  ( __lmline_hash_stdin() { :; }; ! __lmline_async_frontend_key generate >/dev/null )

  cleanup_engine_probe() {
    for name in engine-one engine-two; do
      ( exec 3<>"$LMLINE_TEST_ENGINE_DIR/$name.gate"; printf "release\n" >&3 ) 2>/dev/null || true
    done
    for pid in "${first_pid:-}" "${second_pid:-}"; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_engine_probe EXIT
  READLINE_LINE="# engine"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_generate_widget >/dev/null 2>&1
  first_pid=$__LMLINE_ASYNC_PID
  for i in {1..200}; do [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-one.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-one.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$first_pid" ]]
  LMLINE_ENGINE=$LMLINE_TEST_ENGINE_DIR/engine-two
  __lmline_generate_widget >/dev/null 2>&1
  second_pid=$__LMLINE_ASYNC_PID
  [[ "$second_pid" != "$first_pid" ]]
  [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-one.stopped" && ! -e "$LMLINE_TEST_ENGINE_DIR/engine-one.finished" ]]
  ! kill -0 "$first_pid" 2>/dev/null
  for i in {1..200}; do [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-two.ready" ]] && break; sleep 0.05; done
  [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-two.ready" ]]
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$__LMLINE_ASYNC_PID" == "$second_pid" ]]
  printf "release\n" >"$LMLINE_TEST_ENGINE_DIR/engine-two.gate"
  wait "$second_pid"
  __lmline_generate_widget >/dev/null 2>&1
  [[ "$READLINE_LINE" == "echo from-engine-two" && -s "$LMLINE_TEST_ENGINE_DIR/engine-two.finished" ]]
  [[ ! -e "$LMLINE_TEST_ENGINE_DIR/engine-one.finished" ]]
' _ "$repo_dir" || fail "bash async shell-local engine identity"
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
