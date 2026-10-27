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
  # Exercise the portable digest and ensure failed identities never match a job.
  mkdir "$zsh_tmp/hash-bin"
  for cmd in bash cksum cut; do ln -s "$(command -v "$cmd")" "$zsh_tmp/hash-bin/$cmd"; done
  mkdir "$zsh_tmp/fail-hash-bin"
  ln -s "$(command -v bash)" "$zsh_tmp/fail-hash-bin/bash"
  printf '#!/bin/sh\nprintf "bad digest\\n"\nexit 1\n' >"$zsh_tmp/fail-hash-bin/cksum"
  chmod +x "$zsh_tmp/fail-hash-bin/cksum"
  mkdir "$zsh_tmp/fail-request"
  printf 'source "%s/lmline/context.bash"\n__lmline_request_key() { printf partial; return 1; }\n' "$repo_dir" >"$zsh_tmp/fail-request/context.bash"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-hash" zsh -efic '
    source "$1/lmline/init.zsh"
    (
      export PATH="$2/hash-bin" LMLINE_MODEL=first
      a=$(__lmline_zsh_settings_key)
      [[ "$a" =~ "^[0-9]+[[:space:]][0-9]+$" ]]
      [[ "$a" == "$(__lmline_zsh_settings_key)" ]]
      export LMLINE_MODEL=second
      [[ "$a" != "$(__lmline_zsh_settings_key)" ]]
    )
    # Preserve unset, empty, and trailing newline distinctions in the stream.
    (
      saved_path=$PATH
      bash_bin=$(command -v bash)
      bash() { PATH=$saved_path command "$bash_bin" "$@"; }
      unset PATH; unset_key=$(__lmline_zsh_path_key)
      PATH=; empty_key=$(__lmline_zsh_path_key)
      PATH="value"; value_key=$(__lmline_zsh_path_key)
      PATH=$'"'"'value\n'"'"'; newline_key=$(__lmline_zsh_path_key)
      [[ "$unset_key" != "$empty_key" && "$value_key" != "$newline_key" ]]
    )
    ( export PATH="$2/fail-hash-bin"; ! __lmline_zsh_settings_key >/dev/null )
    (
      LMLINE_DIR=$2/fail-request
      failed=$(__lmline_zsh_request_key generate input 0) && exit 1
      [[ -z "$failed" ]]
    )
    __lmline_zsh_settings_key() { return 1; }
    __lmline_zsh_hint() { :; }
    __lmline_zsh_async_start() { rm -f "$4"; __LMLINE_ZSH_ASYNC_KEY=$5; __LMLINE_ZSH_ASYNC_PID=$$; (( ++starts )); }
    starts=0
    __lmline_zsh_generate_async input generate 0
    __lmline_zsh_generate_async input generate 0
    [[ $starts == 2 && -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
  ' _ "$repo_dir" "$zsh_tmp" || fail "zsh portable settings hash and failed identity"
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
  mkdir "$zsh_tmp/cursor"
  mkfifo "$zsh_tmp/cursor/point-0.gate" "$zsh_tmp/cursor/point-3.gate"
  cat >"$zsh_tmp/engine-cursor" <<'EOF'
#!/usr/bin/env bash
set -eu
point=0
while (($#)); do case "$1" in --point) point=$2; shift 2;; *) shift;; esac; done
stop_file=$LMLINE_TEST_CURSOR_DIR/point-$point.stopped
trap 'printf stopped >"$stop_file"; exit 143' TERM
printf ready >"$LMLINE_TEST_CURSOR_DIR/point-$point.ready"
exec 3<>"$LMLINE_TEST_CURSOR_DIR/point-$point.gate"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_CURSOR_DIR/point-$point.finished"
printf 'lmline-candidate: low\tno matching risk rule\t-\techo point-%s\n' "$point"
EOF
  chmod +x "$zsh_tmp/engine-cursor"
  LMLINE_TEST_CURSOR_DIR="$zsh_tmp/cursor" LMLINE_CONFIG_DIR="$zsh_tmp/config-cursor" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-cursor" zsh -efic '
    source "$1/lmline/init.zsh"
    cleanup_cursor_probe() {
      for point in 0 3; do
        ( exec 3<>"$LMLINE_TEST_CURSOR_DIR/point-$point.gate"; printf "release\n" >&3 ) 2>/dev/null || true
      done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_cursor_probe EXIT
    BUFFER="echo cursor"
    CURSOR=0
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_CURSOR_DIR/point-0.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_CURSOR_DIR/point-0.ready" && "$first_pid" != 0 ]]
    kill -0 "$first_pid" 2>/dev/null
    [[ ! -e "$LMLINE_TEST_CURSOR_DIR/point-0.finished" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" && "$BUFFER" == "echo cursor" ]]
    kill -0 "$first_pid" 2>/dev/null
    CURSOR=3
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second_pid" != 0 && "$second_pid" != "$first_pid" && "$BUFFER" == "echo cursor" ]]
    [[ -s "$LMLINE_TEST_CURSOR_DIR/point-0.stopped" && ! -e "$LMLINE_TEST_CURSOR_DIR/point-0.finished" ]]
    ! kill -0 "$first_pid" 2>/dev/null
    for i in {1..200}; do [[ -s "$LMLINE_TEST_CURSOR_DIR/point-3.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_CURSOR_DIR/point-3.ready" ]]
    ( exec 3<>"$LMLINE_TEST_CURSOR_DIR/point-3.gate"; printf "release\n" >&3 )
    for i in {1..150}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]] && ! kill -0 "$second_pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    [[ -s "$__LMLINE_ZSH_ASYNC_FILE" && -s "$LMLINE_TEST_CURSOR_DIR/point-3.finished" ]]
    ! kill -0 "$second_pid" 2>/dev/null
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo point-3" ]]
  ' _ "$repo_dir" || fail "zsh async cursor identity"
  # Same-path marker replacement cancels pending work and refreshes context.
  mkdir "$zsh_tmp/markers" "$zsh_tmp/markers/rules" "$zsh_tmp/markers/defaults" "$zsh_tmp/markers/fail-bin"
  mkdir "$zsh_tmp/markers/privacy-bin"
  cat >"$zsh_tmp/markers/privacy-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if (($#)) || env | grep -Eq '^(LMLINE_CONFIG_DIR|LMLINE_USER_RULES_DIR|LMLINE_DEFAULTS_DIR|LMLINE_PROJECT_MARKERS_FILE|BASH_FUNC_lmline_marker_privacy%%)='; then
  printf leaked >"$LMLINE_TEST_MARKERS_DIR/leak"
fi
printf checked >"$LMLINE_TEST_MARKERS_DIR/checked"
exec cksum
EOF
  chmod +x "$zsh_tmp/markers/privacy-bin/sha256sum"
  touch "$zsh_tmp/markers/one.marker" "$zsh_tmp/markers/two.marker"
  printf 'one\tone.marker\n' >"$zsh_tmp/markers/list"
  printf 'two\ttwo.marker\n' >"$zsh_tmp/markers/rules/project_markers.tsv"
  printf 'default\tone.marker\n' >"$zsh_tmp/markers/defaults/project_markers.tsv"
  printf '#!/bin/sh\nexit 1\n' >"$zsh_tmp/markers/fail-bin/sha256sum"
  chmod +x "$zsh_tmp/markers/fail-bin/sha256sum"
  mkfifo "$zsh_tmp/markers/one.gate" "$zsh_tmp/markers/two.gate" "$zsh_tmp/markers/absent.gate"
  cat >"$zsh_tmp/engine-markers" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-markers"
  LMLINE_TEST_MARKERS_DIR="$zsh_tmp/markers" LMLINE_CONFIG_DIR="$zsh_tmp/config-markers" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-markers" zsh -efic '
    source "$1/lmline/init.zsh"
    cd "$LMLINE_TEST_MARKERS_DIR"
    cleanup_markers_probe() {
      for n in one two absent; do ( exec 3<>"$LMLINE_TEST_MARKERS_DIR/$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_markers_probe EXIT
    typeset -g LMLINE_USER_RULES_DIR=$PWD/rules LMLINE_DEFAULTS_DIR=$PWD/defaults LMLINE_PROJECT_MARKERS_FILE=$PWD/list
    typeset +x LMLINE_USER_RULES_DIR LMLINE_DEFAULTS_DIR LMLINE_PROJECT_MARKERS_FILE
    ( PATH="$PWD/privacy-bin:$PATH"; __lmline_zsh_project_markers_key >/dev/null )
    [[ -s checked && ! -e leak ]]
    key=$(__lmline_zsh_project_markers_key)
    [[ "$key" != *one* && "$key" != *"$PWD"* ]]
    unset LMLINE_PROJECT_MARKERS_FILE
    user_key=$(__lmline_zsh_project_markers_key)
    [[ "$key" != "$user_key" ]]
    rm rules/project_markers.tsv
    [[ "$user_key" != "$(__lmline_zsh_project_markers_key)" ]]
    typeset -g LMLINE_DEFAULTS_DIR=$1/lmline/defaults LMLINE_PROJECT_MARKERS_FILE=$PWD/list
    ( PATH="$PWD/fail-bin:$PATH"; ! __lmline_zsh_project_markers_key >/dev/null )
    ( typeset -g LMLINE_PROJECT_MARKERS_FILE=$PWD/missing; ! __lmline_zsh_project_markers_key >/dev/null )
    mkfifo fifo
    ( typeset -g LMLINE_PROJECT_MARKERS_FILE=$PWD/fifo; ! __lmline_zsh_project_markers_key >/dev/null )
    ( typeset -g LMLINE_INCLUDE_PROJECT_CONTEXT=off LMLINE_PROJECT_MARKERS_FILE=$PWD/missing
      [[ "$(__lmline_zsh_project_markers_key)" == disabled ]]
      PATH="$PWD/fail-bin:$PATH"
      [[ "$(__lmline_zsh_project_markers_key)" == disabled ]]
    )
    BUFFER="# markers"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s one.ready ]] && break; sleep 0.05; done
    [[ -s one.ready ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first" ]]
    printf "two\ttwo.marker\n" >list
    [[ "$key" != "$(__lmline_zsh_project_markers_key)" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    second=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second" != "$first" && -s one.stopped && "$BUFFER" == "# markers" ]]
    for i in {1..200}; do [[ -s two.ready ]] && break; sleep 0.05; done
    [[ -s two.ready ]]
    printf "release\n" >two.gate
    wait "$second"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo two" ]]
    # Change only marker presence while the absent-context request is pending.
    printf "one\tone.marker\n" >list
    rm one.marker one.ready one.stopped two.ready
    key=$(__lmline_zsh_project_markers_key)
    BUFFER="# markers"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s absent.ready ]] && break; sleep 0.05; done
    [[ -s absent.ready ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first" ]]
    touch one.marker
    [[ "$key" != "$(__lmline_zsh_project_markers_key)" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    second=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second" != "$first" && -s absent.stopped && "$BUFFER" == "# markers" ]]
    ! kill -0 "$first" 2>/dev/null
    for i in {1..200}; do [[ -s one.ready ]] && break; sleep 0.05; done
    [[ -s one.ready ]]
    printf "release\n" >one.gate
    wait "$second"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo one" ]]
    __lmline_zsh_project_markers_key() { return 1; }
    BUFFER="# markers"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$first" ]]
  ' _ "$repo_dir" || fail "zsh project-marker content identity"
  # Git root and branch, but not working-tree status, determine pending identity.
  mkdir "$zsh_tmp/git-probe" "$zsh_tmp/git-probe/repo"
  git -C "$zsh_tmp/git-probe/repo" init -q
  git -C "$zsh_tmp/git-probe/repo" symbolic-ref HEAD refs/heads/one
  mkfifo "$zsh_tmp/git-probe/one.gate" "$zsh_tmp/git-probe/two.gate"
  cat >"$zsh_tmp/engine-git" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-git"
  LMLINE_TEST_GIT_DIR="$zsh_tmp/git-probe" LMLINE_CONFIG_DIR="$zsh_tmp/config-git" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-git" zsh -efic '
    source "$1/lmline/init.zsh"
    cd "$LMLINE_TEST_GIT_DIR/repo"
    cleanup_git_probe() {
      for n in one two; do ( exec 3<>"$LMLINE_TEST_GIT_DIR/$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_git_probe EXIT
    typeset -g LMLINE_INCLUDE_GIT_CONTEXT=off
    typeset +x LMLINE_INCLUDE_GIT_CONTEXT
    [[ "$(__lmline_zsh_git_context_key)" == disabled ]]
    typeset -g LMLINE_INCLUDE_GIT_CONTEXT=1
    ( cd "$LMLINE_TEST_GIT_DIR"; [[ "$(__lmline_zsh_git_context_key)" == absent ]] )
    key=$(__lmline_zsh_git_context_key)
    [[ "$key" != *one* && "$key" != *"$PWD"* ]]
    touch untracked
    [[ "$key" == "$(__lmline_zsh_git_context_key)" ]]
    BUFFER="# git"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_GIT_DIR/one.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_GIT_DIR/one.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first" ]]
    git branch -m two
    [[ "$key" != "$(__lmline_zsh_git_context_key)" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    second=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second" != "$first" && -s "$LMLINE_TEST_GIT_DIR/one.stopped" && "$BUFFER" == "# git" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_GIT_DIR/two.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_GIT_DIR/two.ready" ]]
    printf "release\n" >"$LMLINE_TEST_GIT_DIR/two.gate"
    wait "$second"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo two" ]]
    __lmline_zsh_git_context_key() { return 1; }
    BUFFER="# git"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$first" ]]
  ' _ "$repo_dir" || fail "zsh git context identity"

  # The same unexported resolver settings must select the bridge list.
  mkdir "$zsh_tmp/suggested" "$zsh_tmp/suggested/rules"
  mkdir "$zsh_tmp/suggested/privacy-bin"
  cat >"$zsh_tmp/suggested/privacy-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if (($#)) || env | grep -Eq '^(LMLINE_USER_RULES_DIR|LMLINE_SUGGESTED_COMMANDS_FILE|BASH_FUNC_lmline_privacy_probe%%)='; then
  printf leaked >"$LMLINE_TEST_SUGGESTED_DIR/leak"
fi
printf checked >"$LMLINE_TEST_SUGGESTED_DIR/checked"
exec cksum
EOF
  chmod +x "$zsh_tmp/suggested/privacy-bin/sha256sum"
  mkfifo "$zsh_tmp/suggested/printf.gate" "$zsh_tmp/suggested/sleep.gate"
  printf 'printf\n' >"$zsh_tmp/suggested/rules/suggested_commands.txt"
  mkdir "$zsh_tmp/suggested/fail-bin"
  printf '#!/bin/sh\nprintf "bad digest\\n"\nexit 1\n' >"$zsh_tmp/suggested/fail-bin/sha256sum"
  chmod +x "$zsh_tmp/suggested/fail-bin/sha256sum"
  cat >"$zsh_tmp/engine-suggested" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-suggested"
  LMLINE_TEST_SUGGESTED_DIR="$zsh_tmp/suggested" LMLINE_CONFIG_DIR="$zsh_tmp/config-suggested" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-suggested" zsh -efic '
    source "$1/lmline/init.zsh"
    typeset -g LMLINE_USER_RULES_DIR=$LMLINE_TEST_SUGGESTED_DIR/rules
    unset LMLINE_SUGGESTED_COMMANDS_FILE
    cleanup_suggested_probe() {
      for n in printf sleep; do ( exec 3<>"$LMLINE_TEST_SUGGESTED_DIR/$n.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_suggested_probe EXIT
    typeset +x LMLINE_USER_RULES_DIR
    ( PATH="$LMLINE_TEST_SUGGESTED_DIR/privacy-bin:$PATH"; __lmline_zsh_suggested_commands_key >/dev/null )
    [[ -s "$LMLINE_TEST_SUGGESTED_DIR/checked" && ! -e "$LMLINE_TEST_SUGGESTED_DIR/leak" ]]
    key=$(__lmline_zsh_suggested_commands_key)
    [[ "$key" != *printf* && "$key" != *"$LMLINE_USER_RULES_DIR"* ]]
    ( setopt nounset; __lmline_zsh_suggested_commands_key ) >"$LMLINE_TEST_SUGGESTED_DIR/nounset.out" 2>"$LMLINE_TEST_SUGGESTED_DIR/nounset.err"
    [[ -s "$LMLINE_TEST_SUGGESTED_DIR/nounset.out" && ! -s "$LMLINE_TEST_SUGGESTED_DIR/nounset.err" ]]
    BUFFER="# list"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]]
    # An unchanged PATH reuses pending work; a byte change cancels it.
    path_key=$(__lmline_zsh_path_key)
    [[ "$path_key" != *"$PATH"* ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
    rm -f "$LMLINE_TEST_SUGGESTED_DIR/printf.ready"
    export PATH="$LMLINE_TEST_SUGGESTED_DIR:$PATH"
    [[ "$path_key" != "$(__lmline_zsh_path_key)" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    path_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$first_pid" != "$path_pid" && "$BUFFER" == "# list" && -s "$LMLINE_TEST_SUGGESTED_DIR/printf.stopped" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_SUGGESTED_DIR/printf.ready" ]]
    first_pid=$path_pid
    printf "sleep \n" >"$LMLINE_USER_RULES_DIR/suggested_commands.txt"
    [[ "$key" != "$(__lmline_zsh_suggested_commands_key)" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$first_pid" != "$second_pid" && "$BUFFER" == "# list" && -s "$LMLINE_TEST_SUGGESTED_DIR/printf.stopped" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_SUGGESTED_DIR/sleep.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_SUGGESTED_DIR/sleep.ready" ]]
    printf "release\n" >"$LMLINE_TEST_SUGGESTED_DIR/sleep.gate"
    wait "$second_pid"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo sleep" ]]
    BUFFER="# list"; CURSOR=${#BUFFER}
    printf "printf\n" >"$LMLINE_USER_RULES_DIR/suggested_commands.txt"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$second_pid" && "$BUFFER" == "# list" ]]
    typeset -g LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/missing
    ! __lmline_zsh_suggested_commands_key >/dev/null
    third_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$third_pid" && "$BUFFER" == "# list" ]]
    unset LMLINE_SUGGESTED_COMMANDS_FILE
    ( PATH="$LMLINE_TEST_SUGGESTED_DIR/fail-bin:$PATH"; ! __lmline_zsh_suggested_commands_key >/dev/null )
    ( PATH="$LMLINE_TEST_SUGGESTED_DIR/fail-bin:$PATH"; ! __lmline_zsh_path_key >/dev/null )
    typeset -g LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/missing
    typeset -g LMLINE_INCLUDE_SUGGESTED_COMMANDS=0
    [[ "$(__lmline_zsh_suggested_commands_key)" == disabled ]]
    # Failure or empty output from the PATH digest must never reuse pending work.
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ -n "$__LMLINE_ZSH_ASYNC_KEY" && "$__LMLINE_ZSH_ASYNC_KEY" != function-context-unavailable ]]
    __lmline_zsh_path_key() { return 1; }
    failed_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$failed_pid" && "$BUFFER" == "# list" ]]
    __lmline_zsh_path_key() { return 0; }
    failed_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$failed_pid" && "$BUFFER" == "# list" ]]
  ' _ "$repo_dir" || fail "zsh suggested-command content identity"
  mkdir "$zsh_tmp/settings-change"
  mkdir "$zsh_tmp/settings-change/config"
  printf 'export LMLINE_CANDIDATE_COUNT=1\n' >"$zsh_tmp/settings-change/config/settings.bash"
  mkfifo "$zsh_tmp/settings-change/count-1.gate" "$zsh_tmp/settings-change/count-2.gate" "$zsh_tmp/settings-change/count-3.gate"
  cat >"$zsh_tmp/engine-settings" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-settings"
  LMLINE_TEST_SETTINGS_DIR="$zsh_tmp/settings-change" LMLINE_CONFIG_DIR="$zsh_tmp/settings-change/config" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-settings" zsh -efic '
    source "$1/lmline/init.zsh"
    cleanup_settings_probe() {
      for n in 1 2 3; do
        ( exec 3<>"$LMLINE_TEST_SETTINGS_DIR/count-$n.gate"; printf "release\\n" >&3 ) 2>/dev/null || true
      done
      for pid in "${first_pid:-}" "${second_pid:-}" "${third_pid:-}"; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      done
    }
    trap cleanup_settings_probe EXIT
    BUFFER="# count"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-1.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-1.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
    LMLINE_CANDIDATE_COUNT=2
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$LMLINE_CANDIDATE_COUNT" == 2 && "$second_pid" != "$first_pid" ]]
    [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-1.stopped" ]]
    [[ ! -e "$LMLINE_TEST_SETTINGS_DIR/count-1.finished" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-2.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-2.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$second_pid" ]]
    printf "export LMLINE_CANDIDATE_COUNT=3\\n" >"$LMLINE_CONFIG_DIR/settings.bash"
    lmline-zsh-generate-widget >/dev/null 2>&1
    third_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$LMLINE_CANDIDATE_COUNT" == 3 && "$third_pid" != "$second_pid" ]]
    [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-2.stopped" ]]
    [[ ! -e "$LMLINE_TEST_SETTINGS_DIR/count-2.finished" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-3.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-3.ready" ]]
    printf "release\\n" >"$LMLINE_TEST_SETTINGS_DIR/count-3.gate"
    for i in {1..200}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]] && ! kill -0 "$third_pid" 2>/dev/null; then break; fi
      sleep 0.05
    done
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo count-3" ]]
    [[ -s "$LMLINE_TEST_SETTINGS_DIR/count-3.finished" ]]
  ' _ "$repo_dir" || fail "zsh async candidate-count identity"
  mkdir "$zsh_tmp/model-change"
  mkfifo "$zsh_tmp/model-change/model-one.gate" "$zsh_tmp/model-change/model-two.gate"
  cat >"$zsh_tmp/engine-model" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-model"
  LMLINE_TEST_MODEL_DIR="$zsh_tmp/model-change" LMLINE_CONFIG_DIR="$zsh_tmp/config-model" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-model" LMLINE_MODEL=model-one zsh -efic '
    source "$1/lmline/init.zsh"
  # Framing distinguishes embedded newlines, empty/unset values, and settings
  # that the engine actually inherits; overwritten name transports are ignored.
  export LMLINE_TEST_A="$(printf "one\nLMLINE_TEST_B=two")"
  key_a=$(__lmline_zsh_settings_key)
  export LMLINE_TEST_A=one LMLINE_TEST_B=two
  key_b=$(__lmline_zsh_settings_key)
  [[ "$key_a" != "$key_b" && "$key_a" != *one* ]]
  LMLINE_TEST_B=
  key_empty=$(__lmline_zsh_settings_key)
  unset LMLINE_TEST_B
  [[ "$key_empty" != "$(__lmline_zsh_settings_key)" ]]
  export LMLINE_SHELL_FUNCTIONS=ignored LMLINE_EXPORTED_FUNCTIONS=ignored
  key_a=$(__lmline_zsh_settings_key)
  LMLINE_SHELL_FUNCTIONS=changed LMLINE_EXPORTED_FUNCTIONS=changed
  [[ "$key_a" == "$(__lmline_zsh_settings_key)" ]]
  unset LMLINE_TEST_A LMLINE_SHELL_FUNCTIONS LMLINE_EXPORTED_FUNCTIONS
  typeset -g LMLINE_TEST_GLOBAL=one
  key_a=$(__lmline_zsh_settings_key)
  LMLINE_TEST_GLOBAL=two
  [[ "$key_a" != "$(__lmline_zsh_settings_key)" ]]
  unset LMLINE_TEST_GLOBAL

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
    BUFFER="# model"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_MODEL_DIR/model-one.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_MODEL_DIR/model-one.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
    LMLINE_MODEL=model-two
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second_pid" != "$first_pid" ]]
    [[ -s "$LMLINE_TEST_MODEL_DIR/model-one.stopped" && ! -e "$LMLINE_TEST_MODEL_DIR/model-one.finished" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_MODEL_DIR/model-two.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_MODEL_DIR/model-two.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$second_pid" ]]
    printf "release\n" >"$LMLINE_TEST_MODEL_DIR/model-two.gate"
    wait "$second_pid"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo from-model-two" && -s "$LMLINE_TEST_MODEL_DIR/model-two.finished" ]]
  ' _ "$repo_dir" || fail "zsh async live model identity"
  # A rename changes physical context without changing the shell logical PWD.
  mkdir "$zsh_tmp/cwd-change" "$zsh_tmp/cwd-change/before"
  mkfifo "$zsh_tmp/cwd-change/before.gate" "$zsh_tmp/cwd-change/after.gate" "$zsh_tmp/cwd-change/off.gate"
  cat >"$zsh_tmp/engine-cwd" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-cwd"
  cwd_change_dir=$(cd "$zsh_tmp/cwd-change" && pwd -P)
  LMLINE_TEST_CWD_DIR="$cwd_change_dir" LMLINE_CONFIG_DIR="$zsh_tmp/config-cwd" LMLINE_ASYNC=1 LMLINE_STATUS_MODE=silent LMLINE_ENGINE="$zsh_tmp/engine-cwd" zsh -efic '
    source "$1/lmline/init.zsh"
    LMLINE_INCLUDE_GIT_CONTEXT=0
    LMLINE_INCLUDE_PROJECT_CONTEXT=0
    cleanup_cwd_probe() {
      for name in before after off; do
        ( exec 3<>"$LMLINE_TEST_CWD_DIR/$name.gate"; printf "release\n" >&3 ) 2>/dev/null || true
      done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_cwd_probe EXIT
    cd "$LMLINE_TEST_CWD_DIR/before"
    for enabled in 0 1; do
      typeset -g +x LMLINE_INCLUDE_CWD_CONTEXT=$enabled
      logical=$PWD
      physical=$(pwd -P)
      key=$(__lmline_zsh_request_key generate "# cwd" 5)
      [[ -n "$key" && "$key" != *"$logical"* && "$key" != *"$physical"* ]]
      BUFFER="# cwd"; CURSOR=${#BUFFER}
      lmline-zsh-generate-widget >/dev/null 2>&1
      first_pid=$__LMLINE_ZSH_ASYNC_PID
      name=off; [[ "$enabled" == 0 ]] || name=before
      for i in {1..200}; do [[ -s "$LMLINE_TEST_CWD_DIR/$name.ready" ]] && break; sleep 0.05; done
      [[ -s "$LMLINE_TEST_CWD_DIR/$name.ready" ]]
      mv "$LMLINE_TEST_CWD_DIR/before" "$LMLINE_TEST_CWD_DIR/after"
      [[ "$PWD" == "$logical" && "$(pwd -P)" != "$physical" ]]
      if [[ "$enabled" == 1 ]]; then
        [[ "$key" != "$(__lmline_zsh_request_key generate "# cwd" 5)" ]]
      else
        [[ "$key" == "$(__lmline_zsh_request_key generate "# cwd" 5)" ]]
      fi
      lmline-zsh-generate-widget >/dev/null 2>&1
      second_pid=$__LMLINE_ZSH_ASYNC_PID
      [[ "$BUFFER" == "# cwd" ]]
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
      lmline-zsh-generate-widget >/dev/null 2>&1
      [[ "$BUFFER" == "echo cwd-$name" ]]
      mv "$LMLINE_TEST_CWD_DIR/after" "$LMLINE_TEST_CWD_DIR/before"
    done
  ' _ "$repo_dir" || fail "zsh async physical cwd identity"
  # Shell-local engine changes must cancel pending work, not reuse its result.
  mkdir "$zsh_tmp/engine-change"
  mkfifo "$zsh_tmp/engine-change/engine-one.gate" "$zsh_tmp/engine-change/engine-two.gate"
  cat >"$zsh_tmp/engine-change/engine-one" <<'EOF'
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
  cp "$zsh_tmp/engine-change/engine-one" "$zsh_tmp/engine-change/engine-two"
  chmod +x "$zsh_tmp/engine-change/engine-one" "$zsh_tmp/engine-change/engine-two"
  env -u LMLINE_ENGINE LMLINE_TEST_ENGINE_DIR="$zsh_tmp/engine-change" LMLINE_CONFIG_DIR="$zsh_tmp/config-engine-change" LMLINE_ASYNC=1 zsh -efic '
    source "$1/lmline/init.zsh"
    typeset -g +x LMLINE_ENGINE
    LMLINE_ENGINE=$LMLINE_TEST_ENGINE_DIR/engine-one
    [[ "${parameters[LMLINE_ENGINE]}" == scalar ]]
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
    BUFFER="# engine"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-one.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-one.ready" && "$BUFFER" == "# engine" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
    LMLINE_ENGINE=$LMLINE_TEST_ENGINE_DIR/engine-two
    [[ "${parameters[LMLINE_ENGINE]}" == scalar ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second_pid" != "$first_pid" && "$BUFFER" == "# engine" ]]
    [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-one.stopped" && ! -e "$LMLINE_TEST_ENGINE_DIR/engine-one.finished" ]]
    ! kill -0 "$first_pid" 2>/dev/null
    for i in {1..200}; do [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-two.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_ENGINE_DIR/engine-two.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$second_pid" && "$BUFFER" == "# engine" ]]
    printf "release\n" >"$LMLINE_TEST_ENGINE_DIR/engine-two.gate"
    wait "$second_pid"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo from-engine-two" && -s "$LMLINE_TEST_ENGINE_DIR/engine-two.finished" ]]
    [[ ! -e "$LMLINE_TEST_ENGINE_DIR/engine-one.finished" ]]
  ' _ "$repo_dir" || fail "zsh async shell-local engine identity"
  mkdir "$zsh_tmp/functions-change"
  mkfifo "$zsh_tmp/functions-change/first.gate" "$zsh_tmp/functions-change/second.gate"
  cat >"$zsh_tmp/engine-functions" <<'EOF'
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
  chmod +x "$zsh_tmp/engine-functions"
  LMLINE_TEST_FUNCTIONS_DIR="$zsh_tmp/functions-change" LMLINE_CONFIG_DIR="$zsh_tmp/config-functions" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-functions" zsh -efic '
    source "$1/lmline/init.zsh"
    cleanup_functions_probe() {
      for name in first second; do
        ( exec 3<>"$LMLINE_TEST_FUNCTIONS_DIR/$name.gate"; printf "release\\n" >&3 ) 2>/dev/null || true
      done
      for pid in "${first_pid:-}" "${second_pid:-}"; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      done
    }
    trap cleanup_functions_probe EXIT
    BUFFER="# helper"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first_pid=$__LMLINE_ZSH_ASYNC_PID
    first_file=$__LMLINE_ZSH_ASYNC_FILE
    for i in {1..200}; do [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.ready" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
    [[ "$__LMLINE_ZSH_ASYNC_FILE" == "$first_file" ]]
    available_helper() { printf "body-marker\n" >>"$LMLINE_TEST_FUNCTIONS_DIR/body-ran"; }
    lmline-zsh-generate-widget >/dev/null 2>&1
    second_pid=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second_pid" != "$first_pid" ]]
    [[ "$__LMLINE_ZSH_ASYNC_FILE" != "$first_file" ]]
    [[ "$BUFFER" == "# helper" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.stopped" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/first.stopped" ]]
    [[ ! -e "$LMLINE_TEST_FUNCTIONS_DIR/first.finished" ]]
    ! kill -0 "$first_pid" 2>/dev/null
    [[ ! -e "$first_file" && ! -e "$first_file.status" && ! -e "$first_file.status.err" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/second.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/second.ready" ]]
    printf "release\\n" >"$LMLINE_TEST_FUNCTIONS_DIR/second.gate"
    for i in {1..200}; do
      if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]] && ! kill -0 "$second_pid" 2>/dev/null; then break; fi
      sleep 0.05
    done
    [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo has-helper" ]]
    [[ -s "$LMLINE_TEST_FUNCTIONS_DIR/second.finished" ]]
    [[ ! -e "$LMLINE_TEST_FUNCTIONS_DIR/body-ran" ]]
  ' _ "$repo_dir" || fail "zsh async function identity"
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
