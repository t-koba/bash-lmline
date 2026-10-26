#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: interactive Zsh widgets preserve ZLE integration, async behavior, risk review, and candidate cycling.

if command -v zsh >/dev/null 2>&1; then
  zsh_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-zsh-widget.XXXXXX")
  printf '#!/usr/bin/env bash\nsleep 0.2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-widget\\n"\n' >"$zsh_tmp/engine"
  chmod +x "$zsh_tmp/engine"
  cat >"$zsh_tmp/engine-function" <<'EOF'
#!/usr/bin/env bash
if ! printf '%s\n' "${LMLINE_SHELL_FUNCTIONS-}" | grep -Fxq 'lmline/widget-function-probe'; then
  exit 1
fi
printf 'lmline-candidate: low\tno matching risk rule\t-\tlmline/widget-function-probe\n'
EOF
  chmod +x "$zsh_tmp/engine-function"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-function" LMLINE_ASYNC=0 LMLINE_ENGINE="$zsh_tmp/engine-function" LMLINE_WIDGET_FUNCTION_MARKER="$zsh_tmp/function-called" zsh -efic '
    lmline/widget-function-probe() { : >"$LMLINE_WIDGET_FUNCTION_MARKER"; }
    source "$1/lmline/init.zsh"
    BUFFER="# call the shell function"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-function.out 2>/tmp/lmline-zsh-widget-function.err
    [[ "$BUFFER" == "lmline/widget-function-probe" ]]
    [[ ! -e "$LMLINE_WIDGET_FUNCTION_MARKER" ]]
  ' _ "$repo_dir" || fail "zsh widget hands off function names without executing them"
  # Child Zsh shells enable errexit explicitly so an early failed assertion cannot be masked.
  LMLINE_CONFIG_DIR="$zsh_tmp/config-sync" LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    [[ "$options[interactivecomments]" == on ]]
    [[ $(__lmline_zsh_mode "ls | ") == generate ]]
    [[ $(__lmline_zsh_mode "ls |") == generate ]]
    BUFFER="# say one"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-1.out 2>/tmp/lmline-zsh-widget-1.err
    [[ "$BUFFER" == "echo zsh-widget" ]]
  ' _ "$repo_dir" || fail "zsh sync widget"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-async" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="# say one"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-async-1.out 2>/tmp/lmline-zsh-widget-async-1.err
    [[ "$BUFFER" == "# say one" ]]
    [[ -z $(jobs) ]]
    # The engine writes its answer when it finishes, and the widget reads it
    # only once the engine is gone. The test waits for both instead of for a
    # second, so a loaded machine does not fail it.
    for i in {1..150}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]] && ! kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]]
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-async-2.out 2>/tmp/lmline-zsh-widget-async-2.err
    [[ "$BUFFER" == "echo zsh-widget" ]]
  ' _ "$repo_dir" || fail "zsh async widget"
  # Both generations block on explicit gates; cancellation must stop the first
  # engine AND its child without releasing that gate or touching another job.
  cat >"$zsh_tmp/engine-cancel" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-cancel"
  mkdir "$zsh_tmp/cancel"
  mkfifo "$zsh_tmp/cancel/first.gate" "$zsh_tmp/cancel/second.gate" "$zsh_tmp/cancel/unrelated.gate" "$zsh_tmp/cancel/timeout.gate"
  LMLINE_TEST_ASYNC_DIR="$zsh_tmp/cancel" LMLINE_CONFIG_DIR="$zsh_tmp/config-clean" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-cancel" zsh -efic '
    source "$1/lmline/init.zsh"
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
    BUFFER="# first"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    old_file=$__LMLINE_ZSH_ASYNC_FILE
    old_pid=$__LMLINE_ZSH_ASYNC_PID
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/first.engine.ready"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/first.child.ready"
    BUFFER="# second"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$old_file" != "$__LMLINE_ZSH_ASYNC_FILE" ]]
    [[ "$old_pid" != "$__LMLINE_ZSH_ASYNC_PID" ]]
    [[ "$BUFFER" == "# second" ]]
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
    for i in {1..200}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]] && ! kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null; then break; fi
      sleep 0.05
    done
    [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo second" ]]
    [[ -s "$LMLINE_TEST_ASYNC_DIR/second.engine.finished" ]]
    [[ -s "$LMLINE_TEST_ASYNC_DIR/second.child.finished" ]]
    [[ ! -e "$old_file" && ! -e "$old_file.status" ]]
    # Timeout uses the same cancellation path, not a supervisor-only kill.
    BUFFER="# timeout"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    timeout_file=$__LMLINE_ZSH_ASYNC_FILE
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.engine.ready"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.child.ready"
    __LMLINE_ZSH_ASYNC_STARTED=1
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "# timeout" && $__LMLINE_ZSH_ASYNC_PID == 0 ]]
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.engine.stopped"
    wait_for_file "$LMLINE_TEST_ASYNC_DIR/timeout.child.stopped"
    ! kill -0 "$(cat "$LMLINE_TEST_ASYNC_DIR/timeout.engine.ready")" 2>/dev/null
    ! kill -0 "$(cat "$LMLINE_TEST_ASYNC_DIR/timeout.child.ready")" 2>/dev/null
    [[ ! -e "$timeout_file" && ! -e "$timeout_file.status" && ! -e "$timeout_file.status.err" ]]
    [[ ! -d "$(cat "$LMLINE_TEST_ASYNC_DIR/timeout.context-dir")" ]]
    kill -0 "$unrelated"
  ' _ "$repo_dir" || fail "zsh async cleanup"
  printf '#!/usr/bin/env bash\npoint=0\nwhile (($#)); do case "$1" in --point) point=$2; shift 2;; *) shift;; esac; done\nsleep 0.3\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo point-%%s\\n" "$point"\n' >"$zsh_tmp/engine-cursor"
  chmod +x "$zsh_tmp/engine-cursor"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-cursor" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-cursor" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="echo cursor"
    CURSOR=0
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
    CURSOR=3
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second_pid" != "$first_pid" ]]
    for i in {1..150}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]] && ! kill -0 "$second_pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo point-3" ]]
  ' _ "$repo_dir" || fail "zsh async cursor identity"
  printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: synthetic zsh async failure\\n" >&2\nexit 1\n' >"$zsh_tmp/engine-async-fail"
  chmod +x "$zsh_tmp/engine-async-fail"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-async-fail" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-async-fail" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="# fail"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-async-fail1.out 2>/tmp/lmline-zsh-async-fail1.err
    # The failed engine writes its reason when it finishes, and the widget
    # reports it only once the engine is gone. The test waits for both
    # instead of for a second.
    for i in {1..150}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE.status.err" ]] && ! kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    [[ -s "$__LMLINE_ZSH_ASYNC_FILE.status.err" ]]
    lmline-zsh-generate-widget >/tmp/lmline-zsh-async-fail2.out 2>/tmp/lmline-zsh-async-fail2.err
    grep -q "synthetic zsh async failure" /tmp/lmline-zsh-async-fail2.err
  ' _ "$repo_dir" || fail "zsh async failure hint"
  LMLINE_CONFIG_DIR="$zsh_tmp/config2" LMLINE_ASYNC=0 LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    [[ $(__lmline_zsh_bridge generate generate "# say one" 0) == "lmline-candidate: low"*"echo zsh-widget" ]]
  ' _ "$repo_dir" || fail "zsh bridge"
  printf '#!/usr/bin/env bash\nmode=\nwhile (($#)); do case "$1" in --mode) mode=$2; shift 2;; *) shift;; esac; done\nif [[ "$mode" == explain ]]; then printf "zsh explained\\n"; else printf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-widget\\n"; fi\n' >"$zsh_tmp/engine-explain"
  chmod +x "$zsh_tmp/engine-explain"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-explain" LMLINE_PS0="[lm] " LMLINE_ENGINE="$zsh_tmp/engine-explain" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="echo hi"
    CURSOR=${#BUFFER}
    lmline-zsh-explain-widget >/tmp/lmline-zsh-explain.out 2>/tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] command: echo hi" /tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] risk=low" /tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] command summary:" /tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] model explanation:" /tmp/lmline-zsh-explain.err
    grep -q "zsh explained" /tmp/lmline-zsh-explain.err
  ' _ "$repo_dir" || fail "zsh explain widget"
  printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: curl: (28) Operation timed out after 12003 milliseconds with 0 bytes received\\n" >&2\nexit 1\n' >"$zsh_tmp/engine-fail"
  chmod +x "$zsh_tmp/engine-fail"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-fail" LMLINE_ENGINE="$zsh_tmp/engine-fail" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="# say one"
    CURSOR=${#BUFFER}
    # A failed synchronous engine deliberately makes the widget return 1.
    widget_status=0
    lmline-zsh-generate-widget >/tmp/lmline-zsh-fail.out 2>/tmp/lmline-zsh-fail.err || widget_status=$?
    [[ "$widget_status" == 1 ]]
    [[ "$BUFFER" == "# say one" ]]
    grep -q "request timed out" /tmp/lmline-zsh-fail.err
    grep -q "LMLINE_ENGINE_TIMEOUT" /tmp/lmline-zsh-fail.err
  ' _ "$repo_dir" || fail "zsh engine failure is surfaced"
  printf '#!/usr/bin/env bash\nprintf "lmline-status: m=zsh-model; tok=80/8/88\\n" >&2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-one\\nlmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-two\\n"\n' >"$zsh_tmp/engine"
  chmod +x "$zsh_tmp/engine"
  LMLINE_CONFIG_DIR="$zsh_tmp/config4" LMLINE_ASYNC=0 LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER=""
    CURSOR=0
    lmline-zsh-rewrite-widget >/tmp/lmline-zsh-rewrite-empty.out 2>/tmp/lmline-zsh-rewrite-empty.err
    [[ "$BUFFER" == "" ]]
    BUFFER="echo old"
    CURSOR=${#BUFFER}
    lmline-zsh-rewrite-widget >/tmp/lmline-zsh-rewrite.out 2>/tmp/lmline-zsh-rewrite.err
    [[ "$BUFFER" == "echo zsh-one" ]]
    grep -q "3 candidates; m=zsh-model; tok=80/8/88" /tmp/lmline-zsh-rewrite.err
    lmline-zsh-next-widget
    [[ "$BUFFER" == "echo zsh-two" ]]
    if grep -q "2/3" /tmp/lmline-zsh-rewrite.err; then exit 1; fi
    lmline-zsh-next-widget
    [[ "$BUFFER" == "echo old" ]]
    if grep -q "3/3" /tmp/lmline-zsh-rewrite.err; then exit 1; fi
    lmline-zsh-prev-widget
    [[ "$BUFFER" == "echo zsh-two" ]]
    test -s "$LMLINE_HISTORY_DIR/suggestions.log"
  ' _ "$repo_dir" || fail "zsh rewrite candidate cycling"
  # The suggestion log holds the user own command lines, so it stays user-only.
  LMLINE_CONFIG_DIR="$zsh_tmp/config" LMLINE_ENGINE="$zsh_tmp/engine" LMLINE_HISTORY_DIR="$zsh_tmp/history-mode" zsh -efic '
    source "$1/lmline/init.zsh"
    __lmline_zsh_record_suggestion "generate" "# say one" "echo one"
    [[ -f "$LMLINE_HISTORY_DIR/suggestions.log" ]]
    [[ $(ls -ld "$LMLINE_HISTORY_DIR" | cut -c2-10) == rwx------ ]]
    [[ $(ls -l "$LMLINE_HISTORY_DIR/suggestions.log" | cut -c2-10) == rw------- ]]
  ' _ "$repo_dir" || fail "the zsh suggestion log stays user-only"
  printf '#!/usr/bin/env bash\nprintf "lmline-candidate: medium\\twrites to a file or descriptor\\t-\\techo hi > out.txt\\n"\n' >"$zsh_tmp/engine-medium"
  chmod +x "$zsh_tmp/engine-medium"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-medium" LMLINE_ENGINE="$zsh_tmp/engine-medium" LMLINE_HISTORY_DIR="$zsh_tmp/history-medium" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="# medium"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-medium.out 2>/tmp/lmline-zsh-medium.err
    [[ "$BUFFER" == "echo hi > out.txt" ]]
    grep -q "medium-risk; review before Enter" /tmp/lmline-zsh-medium.err
    grep -q "candidate=" "$LMLINE_HISTORY_DIR/suggestions.log"
  ' _ "$repo_dir" || fail "zsh medium risk and history"
  printf '#!/usr/bin/env bash\nprintf "lmline-candidate: high\\trecursive remove\\t-\\trm -rf /tmp/lmline-zsh-risk-test\\n"\n' >"$zsh_tmp/engine-high"
  chmod +x "$zsh_tmp/engine-high"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-high" LMLINE_ENGINE="$zsh_tmp/engine-high" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="# high"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-high.out 2>/tmp/lmline-zsh-high.err
    [[ "$BUFFER" == "# REVIEW REQUIRED: rm -rf /tmp/lmline-zsh-risk-test" ]]
    grep -q "high-risk; inserted as comment" /tmp/lmline-zsh-high.err
  ' _ "$repo_dir" || fail "zsh high risk hint"
  zsh_fix_marker="$zsh_tmp/fix-disabled-marker"
  zsh_fix_survived="$zsh_tmp/fix-disabled-survived"
  env -u LMLINE_EXEC_BACKEND LMLINE_CONFIG_DIR="$zsh_tmp/config-fix-disabled" LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    LMLINE_EXEC_BACKEND=off
    [[ "${parameters[LMLINE_EXEC_BACKEND]}" == scalar ]]
    bridge_status=0
    __lmline_zsh_run_bridge "fix" fix fix "touch $2" 0 || bridge_status=$?
    [[ "$bridge_status" == 3 ]]
    [[ ! -e "$2" ]]
    [[ "$__LMLINE_ZSH_BRIDGE_OUTPUT" == *"fix execution disabled by LMLINE_EXEC_BACKEND=off"* ]]
    print -r -- survived >"$3"
  ' _ "$repo_dir" "$zsh_fix_marker" "$zsh_fix_survived" || fail "zsh session execution setting reaches fix bridge"
  [[ ! -e "$zsh_fix_marker" && -f "$zsh_fix_survived" ]] || fail "zsh fix kill switch leaves shell alive"
  mkdir -p "$zsh_tmp/config-fix-session"
  printf "export LMLINE_EXEC_BACKEND='local'\n" >"$zsh_tmp/config-fix-session/settings.bash"
  zsh_fix_session_marker="$zsh_tmp/fix-session-disabled-marker"
  zsh_fix_session_survived="$zsh_tmp/fix-session-disabled-survived"
  env -u LMLINE_EXEC_BACKEND LMLINE_CONFIG_DIR="$zsh_tmp/config-fix-session" LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    [[ "$LMLINE_EXEC_BACKEND" == local ]]
    LMLINE_EXEC_BACKEND=off
    typeset -g +x LMLINE_EXEC_BACKEND
    [[ "${parameters[LMLINE_EXEC_BACKEND]}" == scalar ]]
    bridge_status=0
    __lmline_zsh_run_bridge "fix" fix fix "touch $2" 0 || bridge_status=$?
    [[ "$bridge_status" == 3 ]]
    [[ ! -e "$2" ]]
    [[ "$__LMLINE_ZSH_BRIDGE_OUTPUT" == *"fix execution disabled by LMLINE_EXEC_BACKEND=off"* ]]
    print -r -- survived >"$3"
  ' _ "$repo_dir" "$zsh_fix_session_marker" "$zsh_fix_session_survived" || fail "zsh session setting keeps precedence over loaded settings"
  [[ ! -e "$zsh_fix_session_marker" && -f "$zsh_fix_session_survived" ]] || fail "zsh session override survives child config reload"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-notify" LMLINE_ASYNC_NOTIFY=1 zsh -efic '
    source "$1/lmline/init.zsh"
    [[ " ${precmd_functions[@]} " == *"__lmline_zsh_async_prompt_check"* ]]
    source "$1/lmline/init.zsh"
    [[ " ${precmd_functions[@]} " == *"__lmline_zsh_async_prompt_check"* ]]
    count=0
    for fn in "${precmd_functions[@]}"; do [[ "$fn" == __lmline_zsh_async_prompt_check ]] && count=$((count + 1)); done
    (( count == 1 ))
  ' _ "$repo_dir" || fail "zsh async notify precmd wiring"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-no-notify" LMLINE_ASYNC_NOTIFY=0 zsh -efic '
    source "$1/lmline/init.zsh"
    [[ " ${precmd_functions[@]} " != *"__lmline_zsh_async_prompt_check"* ]]
  ' _ "$repo_dir" || fail "zsh async notify stays off by default"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-notify-ready" LMLINE_ASYNC_NOTIFY=1 zsh -efic '
    source "$1/lmline/init.zsh"
    ready=$(mktemp "${TMPDIR:-/tmp}/lmline-zsh-ready.XXXXXX")
    print -r -- "lmline-candidate: low\t-\t-\techo ready" >"$ready"
    __LMLINE_ZSH_ASYNC_FILE=$ready
    __LMLINE_ZSH_ASYNC_PID=999999
    __LMLINE_ZSH_ASYNC_NOTIFIED=0
    tmp_out=$(mktemp "${TMPDIR:-/tmp}/lmline-zsh-ready-out.XXXXXX")
    __lmline_zsh_async_prompt_check 2>"$tmp_out"
    out=$(<"$tmp_out")
    rm -f "$ready" "$tmp_out"
    [[ "$out" == *"suggestion ready"* ]] && (( __LMLINE_ZSH_ASYNC_NOTIFIED == 1 ))
  ' _ "$repo_dir" || fail "zsh async notify announces once"
  rm -rf "$zsh_tmp"
  ok "zsh integration"
else
  printf 'skip - zsh integration (zsh not found)\n'
fi
