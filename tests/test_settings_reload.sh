#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: long-lived shells drop stale file settings on reload while preserving intentional environment values.

reload_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-settings-reload-test.XXXXXX")
trap 'rm -rf "$reload_tmp"' EXIT
cd "$reload_tmp" || fail "test working directory"

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
fi

ok "settings reload drops obsolete values"
