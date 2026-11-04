#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: long-lived shells drop stale file settings on reload while preserving intentional environment values.

reload_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-settings-reload-test.XXXXXX")
trap 'rm -rf "$reload_tmp"' EXIT
cd "$reload_tmp" || fail "test working directory"

# Count full loads, not elapsed time: unchanged startup loads once, failed
# checksums cannot suppress it, and a change between checks still reloads.
for startup_shell in bash zsh; do
  command -v "$startup_shell" >/dev/null 2>&1 || continue
  for startup_case in absent present failed raced; do
    startup_cfg=$reload_tmp/startup-$startup_shell-$startup_case
    mkdir -p "$startup_cfg"
    if [[ "$startup_case" != absent ]]; then
      printf '%s\n' 'export LMLINE_PROGRESS=startup' >"$startup_cfg/settings.bash"
    fi
    LMLINE_CONFIG_DIR="$startup_cfg" "$startup_shell" -fic '
      expected=startup
      case "$3" in
        failed) cksum() { return 1; } ;;
        raced)
          expected=raced
          cksum() {
            command cksum || return
            if [[ ! -e "$LMLINE_CONFIG_DIR/raced" ]]; then
              : >"$LMLINE_CONFIG_DIR/raced"
              printf "%s\n" "export LMLINE_PROGRESS=raced" >"$LMLINE_CONFIG_DIR/settings.bash"
            fi
          }
          ;;
      esac
      PS4="+ "
      set -x
      source "$1/lmline/init.$2"
      set +x
      [[ "$3" == absent || "$LMLINE_PROGRESS" == "$expected" ]]
    ' _ "$repo_dir" "$startup_shell" "$startup_case" \
      >"$startup_cfg/stdout" 2>"$startup_cfg/trace" || fail "$startup_shell startup config ($startup_case)"
    startup_loads=$(grep -Ec '^\++ __lmline_(zsh_)?load_all_config$' "$startup_cfg/trace")
    expected_loads=1
    [[ "$startup_case" != raced ]] || expected_loads=2
    [[ "$startup_loads" == "$expected_loads" ]] || fail "$startup_shell startup load count ($startup_case): $startup_loads"
  done
done

# Long-lived Bash shell: removed file values must not linger, while
# intentional environment values are never cleared.
LMLINE_CONFIG_DIR="$reload_tmp/bash-config" bash --norc -c '
  set -euo pipefail
  export LMLINE_PROGRESS=env-value
  source "$1/lmline/config.bash"
  cfg=$2
  cli=$3
  R() { __lmline_reload_settings_if_changed "$cfg"; }
  # A: config unset drops the value.
  "$cli" config set LMLINE_TOOL_COMMAND_RUN 1 >/dev/null
  R
  [[ "${LMLINE_TOOL_COMMAND_RUN:-}" == 1 ]] || exit 11
  "$cli" config unset LMLINE_TOOL_COMMAND_RUN >/dev/null
  R
  [[ -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 12
  # B: deleted settings file drops file-owned values.
  "$cli" config set LMLINE_ASYNC 1 >/dev/null
  R
  [[ "${LMLINE_ASYNC:-}" == 1 ]] || exit 13
  rm "$cfg/settings.bash"
  R
  [[ -z "${LMLINE_ASYNC-}" ]] || exit 14
  # C: pre-file environment values are restored, not cleared.
  "$cli" config set LMLINE_PROGRESS file-value >/dev/null
  R
  [[ "${LMLINE_PROGRESS:-}" == file-value ]] || exit 15
  "$cli" config unset LMLINE_PROGRESS >/dev/null
  R
  [[ "${LMLINE_PROGRESS:-}" == env-value ]] || exit 16
  # D: user changes made mid-session are preserved.
  "$cli" config set LMLINE_DEBUG 1 >/dev/null
  R
  export LMLINE_DEBUG=user-value
  "$cli" config unset LMLINE_DEBUG >/dev/null
  R
  [[ "${LMLINE_DEBUG:-}" == user-value ]] || exit 17
  # E: profile switches drop keys the new profile does not set.
  "$cli" endpoint add reload-one https://reload-one.invalid/v1 --temperature 0.2 >/dev/null
  "$cli" model add reload-one m1 >/dev/null
  "$cli" endpoint add reload-two https://reload-two.invalid/v1 >/dev/null
  "$cli" model add reload-two m2 >/dev/null
  "$cli" use reload-one m1 >/dev/null
  R
  [[ "${LMLINE_TEMPERATURE:-}" == 0.2 ]] || exit 18
  "$cli" use reload-two m2 >/dev/null
  R
  [[ -z "${LMLINE_TEMPERATURE-}" ]] || exit 19
  # F: ordinary values still apply.
  "$cli" config set LMLINE_ASYNC 1 >/dev/null
  R
  [[ "${LMLINE_ASYNC:-}" == 1 ]] || exit 20
  # G: candidate policy normalizes a file-owned decimal locally, so config
  # reconciliation can still remove the raw file value on the next reload.
  source "$1/lmline/policy.bash"
  "$cli" config set LMLINE_MAX_CANDIDATE_BYTES 010 >/dev/null
  R
  [[ "${LMLINE_MAX_CANDIDATE_BYTES:-}" == 010 ]] || exit 21
  ! __lmline_candidate_truncated 123456789
  [[ "${LMLINE_MAX_CANDIDATE_BYTES:-}" == 010 ]] || exit 22
  "$cli" config unset LMLINE_MAX_CANDIDATE_BYTES >/dev/null
  R
  [[ -z "${LMLINE_MAX_CANDIDATE_BYTES-}" ]] || exit 23
  # H: revoking project-config consent must not reload project-owned settings.
  printf "%s\n" "export LMLINE_PROJECT_CONFIG=1" >"$cfg/settings.bash"
  printf "%s\n" "export LMLINE_TOOL_COMMAND_RUN=1" >"$PWD/.lmline.bash"
  R
  [[ "${LMLINE_PROJECT_CONFIG:-}" == 1 && "${LMLINE_TOOL_COMMAND_RUN:-}" == 1 ]] || exit 24
  : >"$cfg/settings.bash"
  R
  [[ -z "${LMLINE_PROJECT_CONFIG-}" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 25
  R
  [[ -z "${LMLINE_PROJECT_CONFIG-}" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 26
  # Project config cannot restore its own consent on a later settings reload.
  printf "%s\n" \
    "export LMLINE_PROJECT_CONFIG=1" \
    "export LMLINE_TOOL_COMMAND_RUN=1" >"$PWD/.lmline.bash"
  printf "%s\n" "export LMLINE_DEBUG=1" >"$cfg/settings.bash"
  R
  [[ "${LMLINE_DEBUG:-}" == 1 ]] || exit 27
  [[ -z "${LMLINE_PROJECT_CONFIG-}" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 28
' _ "$repo_dir" "$reload_tmp/bash-config" "$repo_dir/lmline/lmline" || fail "Bash settings reload drops obsolete values"

if command -v zsh >/dev/null 2>&1; then
  # Same coverage through the zsh integration and its bridge loader.
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-config" zsh -fic '
    export LMLINE_PROGRESS=env-value
    source "$1/lmline/init.zsh"
    cfg=$2
    cli=$3
    R() { __lmline_zsh_reload_settings_if_changed; }
    "$cli" config set LMLINE_TOOL_COMMAND_RUN 1 >/dev/null
    R
    [[ "${LMLINE_TOOL_COMMAND_RUN:-}" == 1 ]] || exit 11
    "$cli" config unset LMLINE_TOOL_COMMAND_RUN >/dev/null
    R
    [[ -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 12
    "$cli" config set LMLINE_ASYNC 1 >/dev/null
    R
    [[ "${LMLINE_ASYNC:-}" == 1 ]] || exit 13
    rm "$cfg/settings.bash"
    R
    [[ -z "${LMLINE_ASYNC-}" ]] || exit 14
    "$cli" config set LMLINE_PROGRESS file-value >/dev/null
    R
    [[ "${LMLINE_PROGRESS:-}" == file-value ]] || exit 15
    "$cli" config unset LMLINE_PROGRESS >/dev/null
    R
    [[ "${LMLINE_PROGRESS:-}" == env-value ]] || exit 16
    "$cli" config set LMLINE_DEBUG 1 >/dev/null
    R
    export LMLINE_DEBUG=user-value
    "$cli" config unset LMLINE_DEBUG >/dev/null
    R
    [[ "${LMLINE_DEBUG:-}" == user-value ]] || exit 17
    "$cli" endpoint add reload-one https://reload-one.invalid/v1 --temperature 0.2 >/dev/null
    "$cli" model add reload-one m1 >/dev/null
    "$cli" endpoint add reload-two https://reload-two.invalid/v1 >/dev/null
    "$cli" model add reload-two m2 >/dev/null
    "$cli" use reload-one m1 >/dev/null
    R
    [[ "${LMLINE_TEMPERATURE:-}" == 0.2 ]] || exit 18
    "$cli" use reload-two m2 >/dev/null
    R
    [[ -z "${LMLINE_TEMPERATURE-}" ]] || exit 19
    "$cli" config set LMLINE_ASYNC 1 >/dev/null
    R
    [[ "${LMLINE_ASYNC:-}" == 1 ]] || exit 20
    # H: consent revocation clears old project values through the bridge.
    printf "%s\n" "export LMLINE_PROJECT_CONFIG=1" >"$cfg/settings.bash"
    printf "%s\n" "export LMLINE_TOOL_COMMAND_RUN=1" >"$PWD/.lmline.bash"
    R
    [[ "${LMLINE_PROJECT_CONFIG:-}" == 1 && "${LMLINE_TOOL_COMMAND_RUN:-}" == 1 ]] || exit 21
    : >"$cfg/settings.bash"
    R
    [[ -z "${LMLINE_PROJECT_CONFIG-}" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 22
    R
    [[ -z "${LMLINE_PROJECT_CONFIG-}" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 23
    printf "%s\n" \
      "export LMLINE_PROJECT_CONFIG=1" \
      "export LMLINE_TOOL_COMMAND_RUN=1" >"$PWD/.lmline.bash"
    printf "%s\n" "export LMLINE_DEBUG=1" >"$cfg/settings.bash"
    R
    [[ "${LMLINE_DEBUG:-}" == 1 ]] || exit 24
    [[ -z "${LMLINE_PROJECT_CONFIG-}" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 25
  ' _ "$repo_dir" "$reload_tmp/zsh-config" "$repo_dir/lmline/lmline" || fail "zsh settings reload drops obsolete values"
  # Environment-origin project consent survives fresh bridge processes, while
  # a persistent opt-out takes precedence and removing it restores the env gate.
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-env-config" LMLINE_PROJECT_CONFIG=1 zsh -fic '
    cfg=$2
    mkdir -p "$cfg" || exit 30
    : >"$cfg/settings.bash"
    printf "%s\n" "export LMLINE_PROJECT_CONFIG=0" >"$cfg/settings.bash"
    printf "%s\n" "export LMLINE_PROGRESS=project-value" >"$PWD/.lmline.bash"
    unset LMLINE_PROGRESS
    source "$1/lmline/init.zsh"
    [[ "${LMLINE_PROJECT_CONFIG:-}" == 0 && -z "${LMLINE_PROGRESS-}" ]] || exit 31
    source "$1/lmline/init.zsh"
    [[ "${LMLINE_PROJECT_CONFIG:-}" == 0 && -z "${LMLINE_PROGRESS-}" ]] || exit 33
    for value in one two three; do
      printf "%s\n" "export LMLINE_DEBUG=$value" >"$cfg/settings.bash"
      __lmline_zsh_reload_settings_if_changed
      [[ "${LMLINE_PROJECT_CONFIG:-}" == 1 && "${LMLINE_PROGRESS:-}" == project-value ]] || exit 32
    done
  ' _ "$repo_dir" "$reload_tmp/zsh-env-config" || fail "zsh environment project consent survives reload"
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-injection-config" \
    LMLINE_MODEL=$'ordinary\nLMLINE_TOOL_COMMAND_RUN=1' zsh -fic '
    cfg=$2
    mkdir -p "$cfg" || exit 40
    printf "%s\n" "export LMLINE_DEBUG=zero" >"$cfg/settings.bash"
    unset LMLINE_TOOL_COMMAND_RUN
    source "$1/lmline/init.zsh"
    expected=$(printf "ordinary\nLMLINE_TOOL_COMMAND_RUN=1")
    [[ "$LMLINE_MODEL" == "$expected" && -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 41
    printf "%s\n" "export LMLINE_DEBUG=one" >"$cfg/settings.bash"
    __lmline_zsh_reload_settings_if_changed
    [[ "$LMLINE_MODEL" == "$expected" ]] || exit 42
    [[ -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 43
  ' _ "$repo_dir" "$reload_tmp/zsh-injection-config" || fail "zsh bridge preserves multiline environment values"
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-resourced-config" zsh -fic '
    cfg=$2
    mkdir -p "$cfg" || exit 50
    unset LMLINE_TOOL_COMMAND_RUN LMLINE_PROJECT_CONFIG
    printf "%s\n" "export LMLINE_TOOL_COMMAND_RUN=1" >"$cfg/settings.bash"
    source "$1/lmline/init.zsh"
    [[ "${LMLINE_TOOL_COMMAND_RUN-}" == 1 ]] || exit 51
    source "$1/lmline/init.zsh"
    [[ "${LMLINE_TOOL_COMMAND_RUN-}" == 1 ]] || exit 52
    : >"$cfg/settings.bash"
    __lmline_zsh_reload_settings_if_changed
    [[ -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 53
    __lmline_zsh_reload_settings_if_changed
    [[ -z "${LMLINE_TOOL_COMMAND_RUN-}" ]] || exit 54
  ' _ "$repo_dir" "$reload_tmp/zsh-resourced-config" || fail "zsh re-source preserves settings ownership"
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-async-config" zsh -fic '
    cfg=$2
    mkdir -p "$cfg" || exit 60
    : >"$cfg/settings.bash"
    source "$1/lmline/init.zsh"
    file="$cfg/pending-result"
    : >"$file"
    sleep 60 >/dev/null 2>&1 &
    pid=$!
    cleanup_test_async() {
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$file"
    }
    trap cleanup_test_async EXIT
    __LMLINE_ZSH_ASYNC_FILE=$file
    __LMLINE_ZSH_ASYNC_PID=$pid
    __LMLINE_ZSH_ASYNC_KEY=pending-request
    __LMLINE_ZSH_ASYNC_STARTED=123
    __LMLINE_ZSH_ASYNC_NOTIFIED=1
    source "$1/lmline/init.zsh"
    if [[ "$__LMLINE_ZSH_ASYNC_FILE" != "$file" || "$__LMLINE_ZSH_ASYNC_PID" != "$pid" || \
      "$__LMLINE_ZSH_ASYNC_KEY" != pending-request || "$__LMLINE_ZSH_ASYNC_STARTED" != 123 || \
      "$__LMLINE_ZSH_ASYNC_NOTIFIED" != 1 ]]; then
      cleanup_test_async
      exit 61
    fi
    __lmline_zsh_async_cleanup
    [[ -z "$__LMLINE_ZSH_ASYNC_FILE" && "$__LMLINE_ZSH_ASYNC_PID" == 0 && \
      -z "$__LMLINE_ZSH_ASYNC_KEY" && ! -e "$file" ]] || exit 62
    kill -0 "$pid" 2>/dev/null && exit 63
    exit 0
  ' _ "$repo_dir" "$reload_tmp/zsh-async-config" || fail "zsh re-source preserves pending async state"
  # Each public widget refreshes settings once before routing. Generate used
  # to repeat the checksum inside bridge_candidates after its entry check.
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-widget-reload" zsh -fic '
    source "$1/lmline/init.zsh"
    typeset -gi __LMLINE_ZSH_RELOAD_CALLS=0
    __lmline_zsh_reload_settings_if_changed() {
      __LMLINE_ZSH_RELOAD_CALLS=$((__LMLINE_ZSH_RELOAD_CALLS + 1))
    }
    __lmline_zsh_run_bridge() { __LMLINE_ZSH_BRIDGE_OUTPUT=""; return 0; }
    __lmline_zsh_hint() { :; }
    LMLINE_ASYNC=0
    BUFFER="printf ok"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget
    [[ $__LMLINE_ZSH_RELOAD_CALLS == 1 ]] || exit 70
    __LMLINE_ZSH_RELOAD_CALLS=0
    lmline-zsh-rewrite-widget
    [[ $__LMLINE_ZSH_RELOAD_CALLS == 1 ]] || exit 71
    __LMLINE_ZSH_RELOAD_CALLS=0
    lmline-zsh-fix-widget
    [[ $__LMLINE_ZSH_RELOAD_CALLS == 1 ]] || exit 72
  ' _ "$repo_dir" || fail "Zsh widgets reload settings once before routing"
fi

ok "settings reload drops obsolete values"
