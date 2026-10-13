#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

reload_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-settings-reload-test.XXXXXX")
trap 'rm -rf "$reload_tmp"' EXIT
cd "$reload_tmp" || fail "test working directory"

# Long-lived Bash shell: removed file values must not linger, while
# intentional environment values are never cleared.
LMLINE_CONFIG_DIR="$reload_tmp/bash-config" bash --norc -c '
  set -euo pipefail
  export LMLINE_RELOAD_BASELINE=env-value
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
  "$cli" config set LMLINE_RELOAD_BASELINE file-value >/dev/null
  R
  [[ "${LMLINE_RELOAD_BASELINE:-}" == file-value ]] || exit 15
  "$cli" config unset LMLINE_RELOAD_BASELINE >/dev/null
  R
  [[ "${LMLINE_RELOAD_BASELINE:-}" == env-value ]] || exit 16
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
' _ "$repo_dir" "$reload_tmp/bash-config" "$repo_dir/lmline/lmline" || fail "Bash settings reload drops obsolete values"

if command -v zsh >/dev/null 2>&1; then
  # Same coverage through the zsh integration and its bridge loader.
  LMLINE_CONFIG_DIR="$reload_tmp/zsh-config" zsh -fic '
    export LMLINE_RELOAD_BASELINE=env-value
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
    "$cli" config set LMLINE_RELOAD_BASELINE file-value >/dev/null
    R
    [[ "${LMLINE_RELOAD_BASELINE:-}" == file-value ]] || exit 15
    "$cli" config unset LMLINE_RELOAD_BASELINE >/dev/null
    R
    [[ "${LMLINE_RELOAD_BASELINE:-}" == env-value ]] || exit 16
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
  ' _ "$repo_dir" "$reload_tmp/zsh-config" "$repo_dir/lmline/lmline" || fail "zsh settings reload drops obsolete values"
fi

ok "settings reload drops obsolete values"
