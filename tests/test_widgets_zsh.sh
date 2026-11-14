#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: interactive Zsh widgets preserve ZLE integration, async behavior, risk review, and candidate cycling.

if command -v zsh >/dev/null 2>&1; then
  zsh_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-zsh-widget.XXXXXX")
  printf '#!/usr/bin/env bash\nsleep 0.2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-widget\\n"\n' >"$zsh_tmp/engine"
  chmod +x "$zsh_tmp/engine"
  # The version probe remains, but an empty config needs no Bash export bridge.
  bridge_probe_dir="$zsh_tmp/bridge-probe-bin"
  mkdir -p "$bridge_probe_dir" "$zsh_tmp/config-fast-empty" "$zsh_tmp/config-fast-settings"
  real_bash=$(command -v bash)
  cat >"$bridge_probe_dir/bash" <<EOF
#!/bin/sh
case "\${2-}" in
  *BASH_VERSINFO*) exec "$real_bash" "\$@" ;;
  *) : >"\$LM_TEST_BRIDGE_MARKER"; exec "$real_bash" "\$@" ;;
esac
EOF
  chmod +x "$bridge_probe_dir/bash"
  printf 'export LMLINE_MODEL=profile-from-settings\n' >"$zsh_tmp/config-fast-settings/settings.bash"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-fast-empty" LMLINE_PROJECT_CONFIG=0 LMLINE_MODEL=profile-from-env \
    LM_TEST_BRIDGE_MARKER="$zsh_tmp/bridge-no-settings" PATH="$bridge_probe_dir:$PATH" \
    zsh -efic '
      source "$1/lmline/init.zsh"
      [[ "$LMLINE_MODEL" == profile-from-env ]]
      [[ "${__LMLINE_ZSHBASE_LMLINE_MODEL-}" == profile-from-env ]]
      [[ "$__LMLINE_ZSH_SETTINGS_CKSUM" == no-settings-file ]]
    ' _ "$repo_dir" || fail "zsh no-settings fast path preserves the environment baseline"
  [[ ! -e "$zsh_tmp/bridge-no-settings" ]] || fail "zsh no-settings fast path spawned the config bridge"
  # Create a settings file after the no-file seed and before the loader call.
  mkdir -p "$zsh_tmp/config-fast-startup-race"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-fast-startup-race" LMLINE_PROJECT_CONFIG=0 LMLINE_MODEL=profile-from-env \
    zsh -efic '
      setopt DEBUG_BEFORE_CMD
      LM_TEST_RACE_WRITTEN=0
      TRAPDEBUG() {
        if [[ "$ZSH_DEBUG_CMD" == __lmline_zsh_load_all_config &&
              "$__LMLINE_ZSH_SETTINGS_CKSUM" == no-settings-file &&
              "$LM_TEST_RACE_WRITTEN" == 0 &&
              ! -e "$LMLINE_CONFIG_DIR/settings.bash" ]]; then
          LM_TEST_RACE_WRITTEN=1
          print -r -- "export LMLINE_MODEL=profile-from-race" >"$LMLINE_CONFIG_DIR/settings.bash"
        fi
      }
      source "$1/lmline/init.zsh"
      [[ "$LM_TEST_RACE_WRITTEN" == 1 ]]
      [[ "$LMLINE_MODEL" == profile-from-race ]]
      [[ "${__LMLINE_ZSHBASE_LMLINE_MODEL-}" == profile-from-env ]]
    ' _ "$repo_dir" || fail "zsh post-load check catches settings created during startup"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-fast-settings" LMLINE_PROJECT_CONFIG=0 LMLINE_MODEL=profile-from-env \
    LM_TEST_BRIDGE_MARKER="$zsh_tmp/bridge-with-settings" PATH="$bridge_probe_dir:$PATH" \
    zsh -efic '
      source "$1/lmline/init.zsh"
      [[ "$LMLINE_MODEL" == profile-from-settings ]]
      [[ "${__LMLINE_ZSHBASE_LMLINE_MODEL-}" == profile-from-env ]]
    ' _ "$repo_dir" || fail "zsh settings still load through the config bridge"
  [[ -e "$zsh_tmp/bridge-with-settings" ]] || fail "zsh settings skipped the config bridge"
  mkdir -p "$zsh_tmp/config-fast-project" "$zsh_tmp/project-fast"
  git -C "$zsh_tmp/project-fast" init -q
  printf 'export LMLINE_MODEL=profile-from-project\n' >"$zsh_tmp/project-fast/.lmline.bash"
  (
    cd "$zsh_tmp/project-fast"
    LMLINE_CONFIG_DIR="$zsh_tmp/config-fast-project" LMLINE_PROJECT_CONFIG=1 LMLINE_MODEL=profile-from-env \
      LM_TEST_BRIDGE_MARKER="$zsh_tmp/bridge-with-project" PATH="$bridge_probe_dir:$PATH" \
      zsh -efic '
        source "$1/lmline/init.zsh"
        [[ "$LMLINE_MODEL" == profile-from-project ]]
        [[ "${__LMLINE_ZSHBASE_LMLINE_MODEL-}" == profile-from-env ]]
      ' _ "$repo_dir"
  ) || fail "zsh project settings still load through the config bridge"
  [[ -e "$zsh_tmp/bridge-with-project" ]] || fail "zsh project settings skipped the config bridge"
  mkdir -p "$zsh_tmp/config-fast-delete"
  printf 'export LMLINE_MODEL=profile-from-settings\n' >"$zsh_tmp/config-fast-delete/settings.bash"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-fast-delete" LMLINE_PROJECT_CONFIG=0 LMLINE_MODEL=profile-from-env \
    zsh -efic '
      source "$1/lmline/init.zsh"
      [[ "$LMLINE_MODEL" == profile-from-settings ]]
      command rm "$LMLINE_CONFIG_DIR/settings.bash"
      __lmline_zsh_reload_settings_if_changed
      [[ "$LMLINE_MODEL" == profile-from-env ]]
    ' _ "$repo_dir" || fail "zsh settings deletion restores the environment baseline"
  ok "zsh config bridge skips only an empty initial configuration"
  mkdir -p "$zsh_tmp/home-completion-before" "$zsh_tmp/home-completion-after" "$zsh_tmp/config-completion-before" "$zsh_tmp/config-completion-after"
  HOME="$zsh_tmp/home-completion-before" ZDOTDIR="$zsh_tmp/home-completion-before" LMLINE_CONFIG_DIR="$zsh_tmp/config-completion-before" \
    zsh -efic '
      completion_dir="$1/lmline/completions"
      setopt KSH_ARRAYS
      before_count=${#fpath[@]}
      before_first=${fpath[0]}
      before_last=${fpath[$((before_count - 1))]}
      source "$1/lmline/init.zsh"
      [[ -o KSH_ARRAYS ]]
      (( ${#fpath[@]} == before_count + 1 ))
      [[ ${fpath[0]} == "$completion_dir" && ${fpath[1]} == "$before_first" ]]
      [[ ${fpath[$before_count]} == "$before_last" ]]
      source "$1/lmline/init.zsh"
      [[ -o KSH_ARRAYS ]]
      (( ${#fpath[@]} == before_count + 1 ))
      unsetopt KSH_ARRAYS
      [[ ${fpath[(Ie)$completion_dir]} == 1 ]]
      autoload -Uz compinit
      compinit -C
      [[ "${_comps[lmline]-}" == _lmline ]]
    ' _ "$repo_dir" || fail "zsh completion registers when init precedes compinit"
  HOME="$zsh_tmp/home-completion-after" ZDOTDIR="$zsh_tmp/home-completion-after" LMLINE_CONFIG_DIR="$zsh_tmp/config-completion-after" \
    zsh -efic '
      completion_dir="$1/lmline/completions"
      autoload -Uz compinit
      compinit -C
      [[ ${fpath[(Ie)$completion_dir]} == 0 ]]
      source "$1/lmline/init.zsh"
      [[ "${_comps[lmline]-}" == _lmline ]]
      [[ ${fpath[(Ie)$completion_dir]} == 0 ]]
    ' _ "$repo_dir" || fail "zsh completion registration preserves the initialized path"
  # A cached -C dump deliberately skips new fpath entries; a normal compinit
  # pass is the documented one-time refresh when init is sourced first. Use -i
  # so insecure system fpath entries cannot prompt in this noninteractive test.
  mkdir -p "$zsh_tmp/home-completion-cache" "$zsh_tmp/config-completion-cache"
  HOME="$zsh_tmp/home-completion-cache" ZDOTDIR="$zsh_tmp/home-completion-cache" \
    LMLINE_CONFIG_DIR="$zsh_tmp/config-completion-cache" \
    zsh -efic 'autoload -Uz compinit; compinit -i -d "$ZDOTDIR/.zcompdump"' _ "$repo_dir" || fail "zsh creates a pre-init completion cache"
  HOME="$zsh_tmp/home-completion-cache" ZDOTDIR="$zsh_tmp/home-completion-cache" \
    LMLINE_CONFIG_DIR="$zsh_tmp/config-completion-cache" \
    zsh -efic '
      source "$1/lmline/init.zsh"
      autoload -Uz compinit
      compinit -i -d "$ZDOTDIR/.zcompdump"
      [[ "${_comps[lmline]-}" == _lmline ]]
    ' _ "$repo_dir" || fail "zsh refreshes a stale completion cache after init"
  # Replace one cached completion with lmline, keeping the file count equal;
  # removing the exact dump is the deterministic refresh even in this case.
  mkdir -p "$zsh_tmp/home-completion-equal-count" "$zsh_tmp/config-completion-equal-count" "$zsh_tmp/completion-cache-functions"
  printf '#compdef alpha\n_alpha() { return 0; }\n' >"$zsh_tmp/completion-cache-functions/_alpha"
  HOME="$zsh_tmp/home-completion-equal-count" ZDOTDIR="$zsh_tmp/home-completion-equal-count" \
    LMLINE_CONFIG_DIR="$zsh_tmp/config-completion-equal-count" \
    zsh -efic '
      fpath=( "$2" $fpath )
      autoload -Uz compinit
      compinit -i -d "$ZDOTDIR/.zcompdump"
      [[ "${_comps[alpha]-}" == _alpha ]]
    ' _ "$repo_dir" "$zsh_tmp/completion-cache-functions" || fail "zsh seeds an equal-count completion dump"
  command rm "$zsh_tmp/completion-cache-functions/_alpha"
  HOME="$zsh_tmp/home-completion-equal-count" ZDOTDIR="$zsh_tmp/home-completion-equal-count" \
    LMLINE_CONFIG_DIR="$zsh_tmp/config-completion-equal-count" \
    zsh -efic '
      fpath=( "$2" $fpath )
      source "$1/lmline/init.zsh"
      command rm "$ZDOTDIR/.zcompdump"
      autoload -Uz compinit
      compinit -i -d "$ZDOTDIR/.zcompdump"
      [[ "${_comps[lmline]-}" == _lmline ]]
      [[ "${_comps[alpha]-}" != _alpha ]]
    ' _ "$repo_dir" "$zsh_tmp/completion-cache-functions" || fail "zsh refreshes an equal-count completion cache after dump removal"
  ok "zsh CLI completion registers before or after compinit and refreshes stale caches"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-baseline" LMLINE_BASELINE_PROBE=baseline-value LMLINE_bad=ignored LMLINE_=ignored \
    zsh -efic '
      source "$1/lmline/init.zsh"
      [[ "$__LMLINE_ZSHBASE_LMLINE_BASELINE_PROBE" == baseline-value ]]
      __lmline_zsh_key_in_list "$__LMLINE_ZSH_BASELINE_KEYS" LMLINE_BASELINE_PROBE
      ! __lmline_zsh_key_in_list "$__LMLINE_ZSH_BASELINE_KEYS" LMLINE_bad
      ! __lmline_zsh_key_in_list "$__LMLINE_ZSH_BASELINE_KEYS" LMLINE_
    ' _ "$repo_dir" || fail "zsh baseline captures only regex-matching environment keys"
  mkdir -p "$zsh_tmp/config-cleanup" "$zsh_tmp/tmp-cleanup" "$zsh_tmp/config-cleanup-preloaded" "$zsh_tmp/tmp-cleanup-preloaded" "$zsh_tmp/fail-cleanup-bin" "$zsh_tmp/tmp-cleanup-failed"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-cleanup" TMPDIR="$zsh_tmp/tmp-cleanup" zsh -fic '
    was_loaded=0
    builtin zmodload -e zsh/files >/dev/null 2>&1 && was_loaded=1
    before=$(whence -w rm)
    source "$1/lmline/init.zsh"
    [[ $(whence -w rm) == "$before" ]] || exit 84
    if (( was_loaded )); then
      builtin zmodload -e zsh/files >/dev/null 2>&1 || exit 85
    else
      if builtin zmodload -e zsh/files >/dev/null 2>&1; then exit 86; fi
    fi
  ' _ "$repo_dir" || fail "zsh config bridge cleanup restores rm resolution"
  [[ -z "$(find "$zsh_tmp/tmp-cleanup" -maxdepth 1 -name 'lmline-zsh-config.*' -print -quit)" ]] || fail "zsh config bridge removes its temporary export file"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-cleanup-preloaded" TMPDIR="$zsh_tmp/tmp-cleanup-preloaded" zsh -fic '
    was_loaded=0
    builtin zmodload zsh/files >/dev/null 2>&1 && was_loaded=1
    before=$(whence -w rm)
    source "$1/lmline/init.zsh"
    [[ $(whence -w rm) == "$before" ]] || exit 87
    if (( was_loaded )); then builtin zmodload -e zsh/files >/dev/null 2>&1 || exit 88; fi
  ' _ "$repo_dir" || fail "zsh config bridge preserves a preloaded files module"
  [[ -z "$(find "$zsh_tmp/tmp-cleanup-preloaded" -maxdepth 1 -name 'lmline-zsh-config.*' -print -quit)" ]] || fail "zsh config bridge removes temporary export with preloaded module"
  mkdir -p "$zsh_tmp/config-cleanup-partial" "$zsh_tmp/tmp-cleanup-partial"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-cleanup-partial" TMPDIR="$zsh_tmp/tmp-cleanup-partial" zsh -fic '
    builtin zmodload -u zsh/files 2>/dev/null || true
    builtin zmodload -F zsh/files b:mv || exit 90
    before_features=$(builtin zmodload -L -F zsh/files) || exit 91
    source "$1/lmline/init.zsh"
    after_features=$(builtin zmodload -L -F zsh/files) || exit 92
    [[ "$after_features" == "$before_features" ]] || exit 93
    [[ $(whence -w rm) == "rm: command" && $(whence -w mv) == "mv: builtin" ]] || exit 94
  ' _ "$repo_dir" || fail "zsh config cleanup preserves partial zsh/files features"
  [[ -z "$(find "$zsh_tmp/tmp-cleanup-partial" -maxdepth 1 -name 'lmline-zsh-config.*' -print -quit)" ]] || fail "zsh config cleanup handles partial zsh/files state"
  config_fallbacks=(unavailable)
  if zsh -f -c 'builtin zmodload -F zsh/system b:sysopen b:sysseek >/dev/null 2>&1' >/dev/null 2>&1; then
    config_fallbacks+=(collision)
    mkdir -p "$zsh_tmp/config-sysopen" "$zsh_tmp/tmp sysopen" "$zsh_tmp/sysopen-bin"
    cat >"$zsh_tmp/sysopen-bin/mktemp" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$LMLINE_TEST_MKTEMP_MARKER"
exit 97
EOF
    chmod +x "$zsh_tmp/sysopen-bin/mktemp"
    sysopen_real_bash=$(command -v bash)
    cat >"$zsh_tmp/sysopen-bin/bash" <<EOF
#!/bin/sh
case "\${2-}" in
  *BASH_VERSINFO*) exec "$sysopen_real_bash" "\$@" ;;
esac
[ ! -e "\$LMLINE_TEST_EXPORT_PATH" ] && [ ! -L "\$LMLINE_TEST_EXPORT_PATH" ] || { printf 'zsh sysopen test: export path was not unlinked\n' >&2; exit 95; }
mode=\$(stat -L -c '%a' /dev/fd/1 2>/dev/null) || mode=
if [ "\$mode" != 600 ]; then
  exec 3>&1
  mode=\$(perl -e 'open my \$fh, ">&=3" or exit 1; my \$m=(stat \$fh)[2]; defined(\$m) or exit 1; printf "%o\\n", \$m & 0777' 2>/dev/null)
  fstat_status=\$?
  exec 3>&-
  [ "\$fstat_status" -eq 0 ] || { printf 'zsh sysopen test: cannot fstat output descriptor\n' >&2; exit 96; }
fi
[ "\$mode" = 600 ] || { printf 'zsh sysopen test: unexpected inode mode (%s)\n' "\$mode" >&2; exit 97; }
ln -s "\$LMLINE_TEST_VICTIM" "\$LMLINE_TEST_EXPORT_PATH" || { printf 'zsh sysopen test: cannot create replacement path\n' >&2; exit 98; }
[ "\${LMLINE_TEST_EXPORT_FAIL:-0}" = 0 ] || exit 79
exec "$sysopen_real_bash" "\$@"
EOF
    chmod +x "$zsh_tmp/sysopen-bin/bash"
    printf 'sentinel victim\n' >"$zsh_tmp/sysopen-victim"
    printf 'export LMLINE_TEST_PATH_REPLACEMENT=imported\n' >"$zsh_tmp/config-sysopen/settings.bash"
    for system_state in unloaded sysread sysopen sysseek full; do
      LMLINE_CONFIG_DIR="$zsh_tmp/config-sysopen" TMPDIR="$zsh_tmp/tmp sysopen" LMLINE_TEST_VICTIM="$zsh_tmp/sysopen-victim" LMLINE_TEST_MKTEMP_MARKER="$zsh_tmp/mktemp-called" PATH="$zsh_tmp/sysopen-bin:$PATH" zsh -fic '
        builtin zmodload -u zsh/system 2>/dev/null || true
        case "$2" in
          unloaded) ;;
          full) builtin zmodload zsh/system || exit 90 ;;
          *) builtin zmodload -F zsh/system "b:$2" || exit 90 ;;
        esac
        before_features=$(builtin zmodload -L -F zsh/system 2>/dev/null) || before_features=
        export LMLINE_TEST_EXPORT_PATH="$TMPDIR/lmline-zsh-config.$$"
        RANDOM=21971
        first=$RANDOM expected_next=$RANDOM
        RANDOM=21971
        first=$RANDOM
        source "$1/lmline/init.zsh" || { print -u2 -- "sysopen bridge source failed ($2)"; exit 92; }
        [[ "$LMLINE_TEST_PATH_REPLACEMENT" == imported ]] || { print -u2 -- "sysopen config import failed ($2)"; exit 93; }
        after_features=$(builtin zmodload -L -F zsh/system 2>/dev/null) || after_features=
        [[ "$after_features" == "$before_features" ]] || { print -u2 -- "sysopen feature state changed ($2)"; exit 94; }
        [[ $RANDOM == "$expected_next" ]] || { print -u2 -- "sysopen RANDOM state changed ($2)"; exit 98; }
      ' _ "$repo_dir" "$system_state" || fail "zsh sysopen imports through a private unlinked descriptor and preserves $system_state system features"
      [[ $(<"$zsh_tmp/sysopen-victim") == 'sentinel victim' ]] || fail "zsh sysopen pathname replacement cannot overwrite victim"
      [[ -z "$(find "$zsh_tmp/tmp sysopen" -maxdepth 1 -name 'lmline-zsh-config.*' -print -quit)" ]] || fail "zsh sysopen replacement path is cleaned after bridge load"
    done
    LMLINE_CONFIG_DIR="$zsh_tmp/config-sysopen" TMPDIR="$zsh_tmp/tmp sysopen" LMLINE_TEST_VICTIM="$zsh_tmp/sysopen-victim" LMLINE_TEST_EXPORT_FAIL=1 LMLINE_TEST_MKTEMP_MARKER="$zsh_tmp/mktemp-called" PATH="$zsh_tmp/sysopen-bin:$PATH" zsh -fic '
      builtin zmodload -u zsh/system 2>/dev/null || true
      builtin zmodload -F zsh/system b:sysseek || exit 90
      before_features=$(builtin zmodload -L -F zsh/system) || exit 91
      export LMLINE_TEST_EXPORT_PATH="$TMPDIR/lmline-zsh-config.$$"
      source "$1/lmline/init.zsh"
      if __lmline_zsh_load_all_config; then exit 92; fi
      after_features=$(builtin zmodload -L -F zsh/system) || exit 93
      [[ "$after_features" == "$before_features" ]] || exit 94
    ' _ "$repo_dir" || fail "zsh sysopen child failure restores system features"
    [[ $(<"$zsh_tmp/sysopen-victim") == 'sentinel victim' ]] || fail "zsh sysopen failure leaves victim unchanged"
    [[ -z "$(find "$zsh_tmp/tmp sysopen" -maxdepth 1 -name 'lmline-zsh-config.*' -print -quit)" ]] || fail "zsh sysopen replacement path is cleaned after child failure"
    [[ ! -e "$zsh_tmp/mktemp-called" ]] || fail "zsh sysopen avoids external mktemp when available"
  fi
  mkdir -p "$zsh_tmp/pipe-bin" "$zsh_tmp/config-pipe" "$zsh_tmp/tmp-pipe"
  cat >"$zsh_tmp/pipe-bin/mktemp" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$LMLINE_TEST_MKTEMP_MARKER"
ln -s "$LMLINE_TEST_VICTIM" "$LMLINE_TEST_MKTEMP_PATH" || exit 98
printf '%s\n' "$LMLINE_TEST_MKTEMP_PATH"
EOF
  pipe_real_bash=$(command -v bash)
  cat >"$zsh_tmp/pipe-bin/bash" <<EOF
#!/bin/sh
case "\${2-}" in
  *BASH_VERSINFO*) exec "$pipe_real_bash" "\$@" ;;
esac
if [ "\${LMLINE_TEST_PIPE_FAIL:-0}" = 1 ]; then
  printf 'LMLINE_TEST_PIPE_VALUE\\0changed\\0LMLINE_TEST_PIPE_NEW\\0partial\\0'
  exit 79
fi
exec "$pipe_real_bash" "\$@"
EOF
  chmod +x "$zsh_tmp/pipe-bin/"*
  cat >"$zsh_tmp/config-pipe/settings.bash" <<'EOF'
export LMLINE_TEST_PIPE_VALUE='pipe imported'
EOF
  printf 'sentinel victim\n' >"$zsh_tmp/pipe-victim"
  for fallback in "${config_fallbacks[@]}"; do
    for array_mode in default ksh; do
      LMLINE_CONFIG_DIR="$zsh_tmp/config-pipe" TMPDIR="$zsh_tmp/tmp-pipe" \
      LMLINE_TEST_VICTIM="$zsh_tmp/pipe-victim" LMLINE_TEST_MKTEMP_PATH="$zsh_tmp/tmp-pipe/substituted" \
      LMLINE_TEST_MKTEMP_MARKER="$zsh_tmp/pipe-mktemp-called" PATH="$zsh_tmp/pipe-bin:$PATH" zsh -fic '
      [[ "$3" == ksh ]] && setopt KSH_ARRAYS
      builtin zmodload zsh/parameter zsh/regex zsh/zle || exit 89
      builtin zmodload -u zsh/system 2>/dev/null || true
      if [[ "$2" == collision ]]; then
        builtin zmodload -F zsh/system b:sysopen || exit 90
        collision="$TMPDIR/lmline-zsh-config.$$"
        print -r -- sentinel >"$collision"
      else
        module_path=()
      fi
      before_features=$(builtin zmodload -L -F zsh/system 2>/dev/null) || before_features=
      expected_pipe_env="line one
line two
"
      export LMLINE_TEST_PIPE_ENV="$expected_pipe_env"
      export LMLINE_TEST_PIPE_EMPTY=
      coproc { IFS= read -r request; print -r -- "reply:$request"; }
      source "$1/lmline/init.zsh" || exit 91
      [[ "$LMLINE_TEST_PIPE_VALUE" == "pipe imported" &&
         "$LMLINE_TEST_PIPE_ENV" == "$expected_pipe_env" &&
         -v LMLINE_TEST_PIPE_EMPTY && -z "$LMLINE_TEST_PIPE_EMPTY" ]] || exit 92
      print -rp -- preserved
      IFS= read -rp reply
      [[ "$reply" == reply:preserved ]] || exit 93
      before_keys=$__LMLINE_ZSH_BRIDGE_KEYS
      before_stamp=$__LMLINE_ZSHSTAMP_LMLINE_TEST_PIPE_VALUE
      export LMLINE_TEST_PIPE_FAIL=1
      if __lmline_zsh_load_all_config; then exit 94; fi
      [[ "$LMLINE_TEST_PIPE_VALUE" == "$before_stamp" && ! -v LMLINE_TEST_PIPE_NEW &&
         "$__LMLINE_ZSH_BRIDGE_KEYS" == "$before_keys" &&
         "$__LMLINE_ZSHSTAMP_LMLINE_TEST_PIPE_VALUE" == "$before_stamp" ]] || exit 95
      after_features=$(builtin zmodload -L -F zsh/system 2>/dev/null) || after_features=
      [[ "$after_features" == "$before_features" ]] || exit 96
      if [[ -n "$collision" ]]; then
        IFS= read -r content <"$collision"
        [[ "$content" == sentinel ]] || exit 97
        command rm -f "$collision"
      fi
    ' _ "$repo_dir" "$fallback" "$array_mode" || fail "zsh $fallback pipe fallback imports atomically and preserves $array_mode arrays, module state and coprocess"
      [[ $(<"$zsh_tmp/pipe-victim") == 'sentinel victim' ]] || fail "zsh $fallback fallback cannot truncate victim"
      [[ ! -e "$zsh_tmp/pipe-mktemp-called" ]] || fail "zsh $fallback fallback never invokes mktemp"
      [[ -z "$(find "$zsh_tmp/tmp-pipe" -mindepth 1 -print -quit)" ]] || fail "zsh $fallback fallback leaves no temporary path"
    done
  done
  real_bash=$(command -v bash)
  cat >"$zsh_tmp/fail-cleanup-bin/bash" <<EOF
#!/bin/sh
case "\${2-}" in
  *BASH_VERSINFO*) exec "$real_bash" "\$@" ;;
  *) exit 79 ;;
esac
EOF
  chmod +x "$zsh_tmp/fail-cleanup-bin/bash"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-cleanup-failed" TMPDIR="$zsh_tmp/tmp-cleanup-failed" PATH="$zsh_tmp/fail-cleanup-bin:$PATH" zsh -fic '
    before=$(whence -w rm)
    source "$1/lmline/init.zsh"
    [[ $(whence -w rm) == "$before" ]] || exit 89
  ' _ "$repo_dir" || fail "zsh config bridge failure cleanup preserves rm resolution"
  [[ -z "$(find "$zsh_tmp/tmp-cleanup-failed" -maxdepth 1 -name 'lmline-zsh-config.*' -print -quit)" ]] || fail "zsh config bridge removes temporary export after child failure"
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
  # Inject failures at the shared Bash components, not the zsh wrappers: a
  # request now computes every component within the same hardened child.
  mkdir "$zsh_tmp/fail-components"
  printf 'source "%s/lmline/context.bash"\n' "$repo_dir" >"$zsh_tmp/fail-components/context.bash"
  cat >>"$zsh_tmp/fail-components/context.bash" <<'EOF'
case ${LMLINE_TEST_IDENTITY_FAILURE-} in
  project) __lmline_project_markers_key() { return 1; } ;;
  git) __lmline_git_context_key() { return 1; } ;;
  path-fail) __lmline_hash_stdin() { return 1; } ;;
  path-empty) __lmline_hash_stdin() { return 0; } ;;
esac
EOF
  for file in policy.bash actions.bash; do
    ln -s "$repo_dir/lmline/$file" "$zsh_tmp/fail-components/$file"
  done
  # The request bridge loads context without the Bash widget or policy first.
  LMLINE_CONFIG_DIR="$zsh_tmp/config-context" bash --norc -ec '
    source "$1/lmline/context.bash"
    ! declare -F __lmline_collect_shell_functions >/dev/null
    key=$(__lmline_request_key generate input)
    [[ -n "$key" ]]
    expected=$(source "$1/lmline/policy.bash"; __lmline_request_key generate input)
    [[ "$key" == "$expected" ]]
    ! declare -F __lmline_collect_shell_functions >/dev/null
  ' _ "$repo_dir" || fail "context-only request key loads policy privately"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-context-declare" bash --norc -ec '
    source "$1/lmline/context.bash"
    declare() { return 0; }
    export -f declare
    before_options=$-
    before_exports=$(builtin declare -Fx)
    ! builtin declare -F __lmline_collect_shell_functions >/dev/null
    key=$(__lmline_request_key generate input)
    [[ -n "$key" ]]
    expected=$(source "$1/lmline/policy.bash"; __lmline_request_key generate input)
    [[ "$key" == "$expected" ]]
    ! builtin declare -F __lmline_collect_shell_functions >/dev/null
    [[ $- == "$before_options" ]]
    [[ $(builtin declare -Fx) == "$before_exports" ]]
    declare
  ' _ "$repo_dir" || fail "context-only request key ignores exported declare shadow"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-hash" zsh -efic '
    source "$1/lmline/init.zsh"
    request_key=$(__lmline_zsh_request_key generate input 0)
    [[ -n "$request_key" && "$request_key" == "$(__lmline_zsh_request_key generate input 0)" ]]
    (
      export PATH="$2/hash-bin" LMLINE_MODEL=first
      a=$(__lmline_zsh_settings_key)
      [[ "$a" =~ "^[0-9]+[[:space:]][0-9]+$" ]]
      [[ "$a" == "$(__lmline_zsh_settings_key)" ]]
      export LMLINE_MODEL=second
      [[ "$a" != "$(__lmline_zsh_settings_key)" ]]
    )
    # A request launches one privileged Bash, ignoring caller startup code;
    # neither a private scalar nor a function body belongs in its arguments.
    (
      printf "exit 97\n" >"$2/poison-env"
      export BASH_ENV=$2/poison-env
      typeset -g LMLINE_MODEL=private-probe
      private_function() { : private-probe; }
      child_log=$2/identity-children
      bash() { [[ "$1" == -p && "$*" != *private-probe* ]] || return 1; print child >>"$child_log"; command bash "$@"; }
      __lmline_zsh_request_key generate input 0 >/dev/null
      [[ "$(cat "$child_log")" == child ]]
    )
    # Exact parameter types exclude locals (even exported ones) and arrays.
    identity_scope_probe() {
      local LMLINE_MODEL=hidden
      local -x LMLINE_LOCAL_EXPORTED=hidden
      local -a LMLINE_LOCAL_ARRAY=(hidden)
      [[ "$a" == "$(__lmline_zsh_settings_key)" ]]
    }
    a=$(__lmline_zsh_settings_key); identity_scope_probe
    typeset -g LMLINE_MODEL=
    empty=$(__lmline_zsh_settings_key)
    [[ "$a" != "$empty" ]]
    LMLINE_MODEL=value; value=$(__lmline_zsh_settings_key)
    LMLINE_MODEL=$'"'"'value\n'"'"'
    [[ "$value" != "$(__lmline_zsh_settings_key)" ]]
    unset LMLINE_MODEL
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
    __lmline_zsh_identity_key() { return 1; }
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
  # The bridge supervisor runs in Bash, so inject failure through PATH.
  mkdir "$zsh_tmp/fail-publish-bin"
  cat >"$zsh_tmp/fail-publish-bin/mv" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == *.key.tmp.* || "$1" != */lmline-zsh-async.*.tmp.* ]] || exit 1
exec "$LMLINE_TEST_REAL_MV" "$@"
EOF
  chmod +x "$zsh_tmp/fail-publish-bin/mv"
  LMLINE_TEST_REAL_MV="$(command -v mv)" PATH="$zsh_tmp/fail-publish-bin:$PATH" \
  LMLINE_CONFIG_DIR="$zsh_tmp/config-publish-fail" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine" zsh -efic '
    source "$1/lmline/init.zsh"
    BUFFER="# publish"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    async_file=$__LMLINE_ZSH_ASYNC_FILE
    wait "$__LMLINE_ZSH_ASYNC_PID"
    [[ $(cat "$async_file.status") == failed ]]
    [[ ! -e "$async_file" ]]
    stages=("$async_file.tmp."*(N))
    [[ ${#stages} == 0 ]]
    grep -qx "lmline-engine: async result publication failed" "$async_file.status.err"
    lmline-zsh-generate-widget >/dev/null 2>"$2/publish-fail.err"
    grep -q "async result publication failed" "$2/publish-fail.err"
    [[ "$BUFFER" == "# publish" ]]
  ' _ "$repo_dir" "$zsh_tmp" || fail "zsh async publication failure"
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
  if [[ "$name" == unrelated ]]; then
    # This process must remain live until the test explicitly releases it.
    IFS= read -r -u 3 release
  else
    IFS= read -r -t 20 -u 3 release
  fi
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
      # Zsh ERR_EXIT skips EXIT traps when a function returns nonzero.
      cleanup_probe
      return 1
    }
    cleanup_probe() {
      local unrelated_pid=${unrelated:-}
      unrelated=
      # Release blocked fixtures even if an assertion fails on an unfixed build.
      ( exec 3<>"$LMLINE_TEST_ASYNC_DIR/first.gate"; printf "release\n" >&3 )
      ( exec 3<>"$LMLINE_TEST_ASYNC_DIR/second.gate"; printf "release\n" >&3 )
      ( exec 3<>"$LMLINE_TEST_ASYNC_DIR/timeout.gate"; printf "release\n" >&3 )
      if [[ -n "$unrelated_pid" ]]; then
        # Terminate directly: a release sent before the child opens its FIFO
        # is lost when the cleanup descriptor closes, leaving the child blocked.
        kill "$unrelated_pid" 2>/dev/null || true
        wait "$unrelated_pid" 2>/dev/null || true
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
  printf 'printf\n' >"$zsh_tmp/markers/rules/suggested_commands.txt"
  printf 'printf\n' >"$zsh_tmp/markers/defaults/suggested_commands.txt"
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
    typeset -g LMLINE_USER_RULES_DIR=$PWD/rules LMLINE_DEFAULTS_DIR=$PWD/defaults LMLINE_PROJECT_MARKERS_FILE=$PWD/list LMLINE_SUGGESTED_COMMANDS_FILE=$PWD/rules/suggested_commands.txt
    typeset +x LMLINE_USER_RULES_DIR LMLINE_DEFAULTS_DIR LMLINE_PROJECT_MARKERS_FILE LMLINE_SUGGESTED_COMMANDS_FILE
    # Explicit suggested dependency: marker assertions must reflect marker
    # bytes, not an unavailable suggested key.
    suggested_marker_key=$(__lmline_zsh_suggested_commands_key)
    [[ -n "$suggested_marker_key" && "$suggested_marker_key" != *printf* ]]
    ( PATH="$PWD/privacy-bin:$PATH"; __lmline_zsh_project_markers_key >/dev/null; LMLINE_INCLUDE_SUGGESTED_COMMANDS=0; __lmline_zsh_request_key generate input 0 >/dev/null )
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
    LMLINE_DIR=$LMLINE_TEST_MARKERS_DIR/../fail-components
    export LMLINE_TEST_IDENTITY_FAILURE=project
    BUFFER="# markers"; CURSOR=${#BUFFER}
    rm -f one.ready one.stopped
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    first_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ -n "$first" && "$first" != 0 ]]
    for i in {1..200}; do [[ -e "$first_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$first_file.key.failed" && ! -e "$first_file.key" ]]
    ! __lmline_zsh_async_read_key
    [[ -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
    for i in {1..200}; do [[ -s one.ready ]] && break; sleep 0.05; done
    [[ -s one.ready ]]
    # Engine still runs, but the missing key never inserts or reuses.
    lmline-zsh-generate-widget >/dev/null 2>&1
    second=$__LMLINE_ZSH_ASYNC_PID
    second_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ "$second" != "$first" && "$BUFFER" == "# markers" ]]
    for i in {1..200}; do [[ -e "$second_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$second_file.key.failed" && ! -e "$second_file.key" ]]
    printf "release\n" >one.gate
    wait "$second"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "# markers" ]]
  ' _ "$repo_dir" || fail "zsh project-marker content identity"
  # Git root and branch, but not working-tree status, determine pending identity.
  mkdir "$zsh_tmp/git-probe" "$zsh_tmp/git-probe/repo" "$zsh_tmp/git-probe/combined-repo"
  git -C "$zsh_tmp/git-probe/repo" init -q
  git -C "$zsh_tmp/git-probe/repo" symbolic-ref HEAD refs/heads/one
  git -C "$zsh_tmp/git-probe/combined-repo" init -q
  git -C "$zsh_tmp/git-probe/combined-repo" symbolic-ref HEAD refs/heads/combined
  real_git=$(type -P git)
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
  mkdir "$zsh_tmp/git-probe/combined-bin"
  cat >"$zsh_tmp/git-probe/combined-bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$LMLINE_GIT_CALLS"
exec "$LMLINE_TEST_REAL_GIT" "$@"
EOF
  chmod +x "$zsh_tmp/git-probe/combined-bin/git"
  LMLINE_TEST_GIT_DIR="$zsh_tmp/git-probe" LMLINE_TEST_REAL_GIT="$real_git" LMLINE_CONFIG_DIR="$zsh_tmp/config-git" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-git" zsh -efic '
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
    (
      export PATH="$LMLINE_TEST_GIT_DIR/combined-bin:$PATH"
      export LMLINE_GIT_CALLS="$LMLINE_TEST_GIT_DIR/combined.calls"
      : >"$LMLINE_GIT_CALLS"
      cd "$LMLINE_TEST_GIT_DIR/combined-repo"
      combined_one=$(__lmline_zsh_git_context_key)
      combined_two=$(__lmline_zsh_git_context_key)
      [[ -n "$combined_one" && "$combined_one" == "$combined_two" ]]
      [[ $(grep -c "^rev-parse --is-inside-work-tree --show-toplevel$" "$LMLINE_GIT_CALLS") == 2 ]]
      [[ $(grep -c "^branch --show-current$" "$LMLINE_GIT_CALLS") == 2 ]]
      ! grep -Fqx "rev-parse --is-inside-work-tree" "$LMLINE_GIT_CALLS"
      ! grep -Fqx "rev-parse --show-toplevel" "$LMLINE_GIT_CALLS"
    )
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
    LMLINE_DIR=$LMLINE_TEST_GIT_DIR/../fail-components
    export LMLINE_TEST_IDENTITY_FAILURE=git
    BUFFER="# git"; CURSOR=${#BUFFER}
    rm -f "$LMLINE_TEST_GIT_DIR/two.ready" "$LMLINE_TEST_GIT_DIR/two.stopped"
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    first_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ -n "$first" && "$first" != 0 ]]
    for i in {1..200}; do [[ -e "$first_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$first_file.key.failed" && ! -e "$first_file.key" ]]
    ! __lmline_zsh_async_read_key
    [[ -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_GIT_DIR/two.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_GIT_DIR/two.ready" ]]
    # Engine still runs, but the missing key never inserts or reuses.
    lmline-zsh-generate-widget >/dev/null 2>&1
    second=$__LMLINE_ZSH_ASYNC_PID
    second_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ "$second" != "$first" && "$BUFFER" == "# git" ]]
    for i in {1..200}; do [[ -e "$second_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$second_file.key.failed" && ! -e "$second_file.key" ]]
    printf "release\n" >"$LMLINE_TEST_GIT_DIR/two.gate"
    wait "$second"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "# git" ]]
  ' _ "$repo_dir" || fail "zsh git context identity"

  # A real Bash parent exports a harmless body. Zsh retains its transport, so
  # inspect both raw records and import at the actual suggested-key hash child.
  mkdir "$zsh_tmp/identity-bin" "$zsh_tmp/identity-rules"
  printf 'printf\n' >"$zsh_tmp/identity-rules/suggested_commands.txt"
  cat >"$zsh_tmp/identity-bin/sha256sum" <<'EOF_HASH'
#!/usr/bin/env bash
raw=0 imported=0 ordinary=0 scratch=0
while IFS= read -r -d '' record; do
  case ${record%%=*} in
    BASH_FUNC_*%%|lmline_inherited_probe|lmline_legacy_probe|LMLINE_LEGACY_PROBE) raw=1 ;;
    __lmline_env_record|__lmline_env_name|__lmline_env_status|__lmline_env_unset) scratch=1 ;;
  esac
done < <(/usr/bin/env -0)
if declare -F lmline_inherited_probe >/dev/null || declare -F lmline_legacy_probe >/dev/null; then imported=1; fi
[[ ${TEXT-} == '()example' && ${ORDINARY-} == $'value=with\nnewlines\n' ]] && ordinary=1
printf 'raw=%s imported=%s ordinary=%s scratch=%s\n' "$raw" "$imported" "$ordinary" "$scratch" >>"$LMLINE_TEST_IDENTITY_LOG"
exec cksum "$@"
EOF_HASH
  chmod +x "$zsh_tmp/identity-bin/sha256sum"
  cat >"$zsh_tmp/identity-probe.zsh" <<'EOF_ZSH'
source "$1/lmline/init.zsh"
typeset -g LMLINE_USER_RULES_DIR=$2/identity-rules
typeset +x LMLINE_USER_RULES_DIR
PATH="$2/identity-bin:$PATH"
# The launch boundary may pass names, but never transport values, in argv.
function /usr/bin/env() {
  local arg
  for arg in "$@"; do
    [[ $arg != *inherited-body-marker* && $arg != *legacy-body-marker* ]] || return 1
  done
  command /usr/bin/env "$@"
}
# Caller shell state, including the inherited transport, must remain intact.
parent_records() {
  local record found=0
  while IFS= read -r -d '' record; do
    [[ ${record%%=*} == BASH_FUNC_*%% || ${record%%=*} == lmline_inherited_probe || ${record%%=*} == lmline_legacy_probe ]] && found=1
  done < <(/usr/bin/env -0)
  print -r -- "$found"
}
[[ $(parent_records) == $3 ]]
key=$(__lmline_zsh_suggested_commands_key)
[[ -n "$key" && "$key" == "$(__lmline_zsh_suggested_commands_key)" ]]
[[ $(parent_records) == $3 ]]
print -r -- "$key"
# A legacy LMLINE_* function must not enter the framed settings snapshot.
__lmline_zsh_settings_key
print
# Reserved transport in explicitly framed settings must not become stdin or
# argv data either. Treat it exactly like absent settings, without mutation.
(
  unset LMLINE_PROMPT_VERSION LMLINE_CANDIDATE_COUNT
  clean=$(__lmline_zsh_request_key generate input 0)
  export LMLINE_PROMPT_VERSION="() { : legacy-body-marker; }"
  export LMLINE_CANDIDATE_COUNT="() { : legacy-body-marker; }"
  [[ "$clean" == "$(__lmline_zsh_request_key generate input 0)" ]]
  [[ $LMLINE_PROMPT_VERSION == *legacy-body-marker* && $LMLINE_CANDIDATE_COUNT == *legacy-body-marker* ]]
)
# Tracing and allexport must not expose scanner values, and must be restored.
(
  setopt xtrace allexport
  __lmline_zsh_suggested_commands_key >"$2/traced.key"
  [[ -o xtrace && -o allexport ]]
) 2>"$2/identity.trace"
[[ $(<"$2/traced.key") == "$key" ]]
# Simulate failed, unterminated and missing-status enumeration, then failed
# sanitation. No failure may invoke an identity child or produce a key.
identity_failure_marker=$2/unexpected-identity
for failure in status partial missing sanitation; do
  (
    function /usr/bin/env() {
      if [[ $failure == sanitation ]]; then
        [[ $1 == -0 ]] && { command /usr/bin/env "$@"; return; }
        return 1
      fi
      builtin printf 'PARTIAL=value'
      [[ $failure == partial ]] && exit 0
      builtin printf '\0'
      [[ $failure == missing ]] && exit 0
      return 1
    }
    bash() { print invoked >"$identity_failure_marker"; return 1; }
    # A clean environment needs no sanitation; test that failure only dirty.
    [[ $failure != sanitation || $3 == 1 ]] || exit 0
    failed=$(__lmline_zsh_suggested_commands_key) && exit 1
    [[ -z "$failed" && ! -e "$2/unexpected-identity" ]]
  )
done
EOF_ZSH
  for inherited in 0 1; do
    LMLINE_CONFIG_DIR="$zsh_tmp/config-identity" LMLINE_TEST_IDENTITY_LOG="$zsh_tmp/identity.log" \
      bash --noprofile --norc -ec '
        export TEXT="()example" __lmline_env_record=scratch-collision __lmline_env_name=scratch-collision __lmline_env_status=scratch-collision __lmline_env_unset=scratch-collision ORDINARY=$'"'"'value=with\nnewlines\n'"'"'
        if [[ $3 == 1 ]]; then
          lmline_inherited_probe() { : inherited-body-marker; }
          export -f lmline_inherited_probe
          export lmline_legacy_probe="() { : legacy-body-marker; }"
          export LMLINE_LEGACY_PROBE="() { : legacy-body-marker; }"
        fi
        exec zsh -efi "$2/identity-probe.zsh" "$1" "$2" "$3"
      ' _ "$repo_dir" "$zsh_tmp" "$inherited" >"$zsh_tmp/identity-$inherited.key" || fail "zsh inherited function boundary ($inherited)"
    mv "$zsh_tmp/identity.log" "$zsh_tmp/identity-$inherited.log"
    [[ -s "$zsh_tmp/identity-$inherited.log" ]] || fail "zsh inherited function hash child ran"
    if grep -qv '^raw=0 imported=0 ordinary=1 scratch=0$' "$zsh_tmp/identity-$inherited.log"; then
      fail "zsh inherited function hash child privacy and ordinary environment"
    fi
    if grep -Eq 'inherited-body-marker|legacy-body-marker|PARTIAL=value' "$zsh_tmp/identity.trace"; then
      fail "zsh inherited function scanner trace privacy"
    fi
  done
  cmp -s "$zsh_tmp/identity-0.key" "$zsh_tmp/identity-1.key" || fail "zsh inherited function exact suggested key parity"
  # The same unexported resolver settings must select the bridge list.
  mkdir "$zsh_tmp/suggested" "$zsh_tmp/suggested/rules"
  mkdir "$zsh_tmp/suggested/privacy-bin"
  cat >"$zsh_tmp/suggested/privacy-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
if [[ $# != 0 && ( $# != 2 || $1 != /dev/fd/* || $2 != /dev/fd/* ) ]] || env | grep -Eq '^(LMLINE_USER_RULES_DIR|LMLINE_SUGGESTED_COMMANDS_FILE|BASH_FUNC_lmline_privacy_probe%%)='; then
  printf leaked >"$LMLINE_TEST_SUGGESTED_DIR/leak"
fi
printf checked >"$LMLINE_TEST_SUGGESTED_DIR/checked"
exec cksum "$@"
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
    ( PATH="$LMLINE_TEST_SUGGESTED_DIR/privacy-bin:$PATH"; __lmline_zsh_suggested_commands_key >/dev/null; __lmline_zsh_request_key generate input 0 >/dev/null )
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
    # Wait for the pending printf key so the missing-file restart is decided
    # by exact live revalidation, not by a still-preparing supervisor.
    printf_wait=$__LMLINE_ZSH_ASYNC_FILE
    for i in {1..200}; do [[ -s "$printf_wait.key" ]] && break; sleep 0.05; done
    [[ -s "$printf_wait.key" ]]
    typeset -g LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/missing
    ! __lmline_zsh_suggested_commands_key >/dev/null
    third_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    third_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$third_pid" && "$BUFFER" == "# list" ]]
    for i in {1..200}; do [[ -e "$third_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$third_file.key.failed" && ! -e "$third_file.key" ]]
    ! __lmline_zsh_async_read_key
    [[ -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
    unset LMLINE_SUGGESTED_COMMANDS_FILE
    ( PATH="$LMLINE_TEST_SUGGESTED_DIR/fail-bin:$PATH"; ! __lmline_zsh_suggested_commands_key >/dev/null )
    ( PATH="$LMLINE_TEST_SUGGESTED_DIR/fail-bin:$PATH"; ! __lmline_zsh_path_key >/dev/null )
    typeset -g LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_SUGGESTED_DIR/missing
    typeset -g LMLINE_INCLUDE_SUGGESTED_COMMANDS=0
    [[ "$(__lmline_zsh_suggested_commands_key)" == disabled ]]
    # Failure or empty output from the PATH digest must never reuse pending work.
    lmline-zsh-generate-widget >/dev/null 2>&1
    for i in {1..200}; do [[ -s "$__LMLINE_ZSH_ASYNC_FILE.key" ]] && break; sleep 0.05; done
    __lmline_zsh_async_read_key
    [[ -n "$__LMLINE_ZSH_ASYNC_KEY" ]]
    LMLINE_DIR=$LMLINE_TEST_SUGGESTED_DIR/../fail-components
    export LMLINE_TEST_IDENTITY_FAILURE=path-fail
    failed_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    failed_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$failed_pid" && "$BUFFER" == "# list" ]]
    for i in {1..200}; do [[ -e "$failed_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$failed_file.key.failed" && ! -e "$failed_file.key" ]]
    ! __lmline_zsh_async_read_key
    [[ -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
    export LMLINE_TEST_IDENTITY_FAILURE=path-empty
    failed_pid=$__LMLINE_ZSH_ASYNC_PID
    lmline-zsh-generate-widget >/dev/null 2>&1
    failed_file=$__LMLINE_ZSH_ASYNC_FILE
    [[ "$__LMLINE_ZSH_ASYNC_PID" != "$failed_pid" && "$BUFFER" == "# list" ]]
    for i in {1..200}; do [[ -e "$failed_file.key.failed" ]] && break; sleep 0.05; done
    [[ -e "$failed_file.key.failed" && ! -e "$failed_file.key" ]]
    ! __lmline_zsh_async_read_key
    [[ -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
  ' _ "$repo_dir" || fail "zsh suggested-command content identity"
  # Availability changes inside an existing PATH directory invalidate pending work.
  mkdir "$zsh_tmp/availability" "$zsh_tmp/availability/bin"
  printf 'lmline-availability-external\n' >"$zsh_tmp/availability/list"
  for phase in absent external; do mkfifo "$zsh_tmp/availability/$phase.gate"; done
  cat >"$zsh_tmp/engine-availability" <<'EOF'
#!/usr/bin/env bash
set -eu
while (($#)); do case "$1" in --context-file) context=$2; shift 2;; *) shift;; esac; done
phase=absent
if grep -qx lmline-availability-external "$context"; then phase=external; fi
grep -x lmline-availability-external "$context" >"$LMLINE_TEST_AVAILABILITY_DIR/$phase.members" || true
trap 'printf stopped >"$LMLINE_TEST_AVAILABILITY_DIR/$phase.stopped"; exit 143' TERM
printf ready >"$LMLINE_TEST_AVAILABILITY_DIR/$phase.ready"
exec 3<>"$LMLINE_TEST_AVAILABILITY_DIR/$phase.gate"
IFS= read -r -t 20 -u 3 release
printf 'lmline-candidate: low\t-\t-\techo %s\n' "$phase"
EOF
  chmod +x "$zsh_tmp/engine-availability"
  LMLINE_TEST_AVAILABILITY_DIR="$zsh_tmp/availability" LMLINE_CONFIG_DIR="$zsh_tmp/config-availability" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-availability" zsh -efic '
    source "$1/lmline/init.zsh"
    typeset -g LMLINE_SUGGESTED_COMMANDS_FILE=$LMLINE_TEST_AVAILABILITY_DIR/list
    export PATH="$LMLINE_TEST_AVAILABILITY_DIR/bin:$PATH"
    cleanup_availability_probe() {
      for phase in absent external; do ( exec 3<>"$LMLINE_TEST_AVAILABILITY_DIR/$phase.gate"; printf "release\n" >&3 ) 2>/dev/null || true; done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_availability_probe EXIT
    initial_path=$PATH
    list_bytes=$(cksum <"$LMLINE_SUGGESTED_COMMANDS_FILE")
    key=$(__lmline_zsh_suggested_commands_key)
    [[ -n "$key" && "$key" != *lmline-availability* && "$key" != *"$LMLINE_SUGGESTED_COMMANDS_FILE"* ]]
    BUFFER="# availability"; CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/dev/null 2>&1
    first=$__LMLINE_ZSH_ASYNC_PID
    for i in {1..200}; do [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.ready" && ! -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.members" ]]
    __lmline_zsh_async_read_key; first_key=$__LMLINE_ZSH_ASYNC_KEY
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first" ]]
    printf "#!/bin/sh\nexit 0\n" >"$LMLINE_TEST_AVAILABILITY_DIR/bin/lmline-availability-external"
    chmod +x "$LMLINE_TEST_AVAILABILITY_DIR/bin/lmline-availability-external"
    [[ "$PATH" == "$initial_path" && "$(cksum <"$LMLINE_SUGGESTED_COMMANDS_FILE")" == "$list_bytes" ]]
    [[ "$key" != "$(__lmline_zsh_suggested_commands_key)" ]]
    lmline-zsh-generate-widget >/dev/null 2>&1
    second=$__LMLINE_ZSH_ASYNC_PID
    [[ "$second" != "$first" && "$BUFFER" == "# availability" && -s "$LMLINE_TEST_AVAILABILITY_DIR/absent.stopped" ]]
    for i in {1..200}; do [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/external.ready" ]] && break; sleep 0.05; done
    [[ -s "$LMLINE_TEST_AVAILABILITY_DIR/external.ready" ]]
    __lmline_zsh_async_read_key
    [[ "$__LMLINE_ZSH_ASYNC_KEY" != "$first_key" ]]
    [[ "$(cat "$LMLINE_TEST_AVAILABILITY_DIR/external.members")" == lmline-availability-external ]]
    printf "release\n" >"$LMLINE_TEST_AVAILABILITY_DIR/external.gate"
    wait "$second"
    lmline-zsh-generate-widget >/dev/null 2>&1
    [[ "$BUFFER" == "echo external" ]]
  ' _ "$repo_dir" || fail "zsh suggested-command availability identity"
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
  # Only private uname output changes: PATH and the shim remain unchanged.
  mkdir "$zsh_tmp/uname-change" "$zsh_tmp/uname-change/bin"
  mkfifo "$zsh_tmp/uname-change/one.gate" "$zsh_tmp/uname-change/two.gate" "$zsh_tmp/uname-change/off.gate"
  cat >"$zsh_tmp/uname-change/bin/uname" <<'EOF'
#!/bin/sh
[ "$#" = 1 ] && [ "$1" = -a ] || exit 97
printf invoked >>"$LMLINE_TEST_UNAME_DIR/calls"
cat "$LMLINE_TEST_UNAME_DIR/output"
[ ! -e "$LMLINE_TEST_UNAME_DIR/fail" ]
EOF
  cat >"$zsh_tmp/engine-uname" <<'EOF'
#!/usr/bin/env bash
set -eu
context=
while (($#)); do
  case $1 in --context-file) context=$2; shift 2 ;; *) shift ;; esac
done
if ! grep -q '^## shell$' "$context"; then name=off
elif grep -Fxq 'uname=private-uname-one' "$context"; then name=one
elif grep -Fxq 'uname=private-uname-two' "$context"; then name=two
else exit 98
fi
trap 'printf stopped >"$LMLINE_TEST_UNAME_DIR/$name.stopped"; exit 143' TERM
exec 3<>"$LMLINE_TEST_UNAME_DIR/$name.gate"
printf ready >"$LMLINE_TEST_UNAME_DIR/$name.ready"
IFS= read -r -t 20 -u 3 release
printf finished >"$LMLINE_TEST_UNAME_DIR/$name.finished"
printf 'lmline-candidate: low\t-\t-\ttouch uname-candidate-executed # %s\n' "$name"
EOF
  chmod +x "$zsh_tmp/uname-change/bin/uname" "$zsh_tmp/engine-uname"
  LMLINE_TEST_UNAME_DIR="$zsh_tmp/uname-change" LMLINE_CONFIG_DIR="$zsh_tmp/config-uname" LMLINE_ASYNC=1 LMLINE_STATUS_MODE=silent LMLINE_ENGINE="$zsh_tmp/engine-uname" zsh -efic '
    source "$1/lmline/init.zsh"
    export PATH="$LMLINE_TEST_UNAME_DIR/bin:$PATH"
    export LMLINE_INCLUDE_CWD_CONTEXT=0 LMLINE_INCLUDE_GIT_CONTEXT=0
    export LMLINE_INCLUDE_PROJECT_CONTEXT=0 LMLINE_INCLUDE_SUGGESTED_COMMANDS=0
    export LMLINE_TOOL_MODE=none
    cleanup_uname_probe() {
      for name in one two off; do
        ( exec 3<>"$LMLINE_TEST_UNAME_DIR/$name.gate"; printf "release\n" >&3 ) 2>/dev/null || true
      done
      __lmline_zsh_async_cleanup
    }
    trap cleanup_uname_probe EXIT
    cd "$LMLINE_TEST_UNAME_DIR"
    # Key equivalence must match the actual context produced by sed,
    # regardless of platform-specific final-line handling.
    export LMLINE_INCLUDE_SHELL_CONTEXT=1
    printf "private-uname-one" >output
    plain=$(__lmline_zsh_request_key generate "# uname" 7)
    bash -c "source \"\$1/lmline/context.bash\"; __lmline_context_file \"\$2\" \"# uname\" generate" _ "$1" plain-context
    printf "private-uname-one\n" >output
    nl_key=$(__lmline_zsh_request_key generate "# uname" 7)
    bash -c "source \"\$1/lmline/context.bash\"; __lmline_context_file \"\$2\" \"# uname\" generate" _ "$1" nl-context
    if cmp -s plain-context nl-context; then [[ "$plain" == "$nl_key" ]]; else [[ "$plain" != "$nl_key" ]]; fi
    rm -f calls
    for enabled in 0 1; do
      typeset -g +x LMLINE_INCLUDE_SHELL_CONTEXT=$enabled
      [[ "${parameters[LMLINE_INCLUDE_SHELL_CONTEXT]}" == scalar ]]
      printf "private-uname-one\n" >output
      rm -f calls
      key=$(__lmline_zsh_request_key generate "# uname" 7)
      [[ -n "$key" && "$key" != *private-uname-one* && "$key" != *"$LMLINE_TEST_UNAME_DIR"* ]]
      BUFFER="# uname"; CURSOR=${#BUFFER}
      lmline-zsh-generate-widget >/dev/null 2>&1
      first_pid=$__LMLINE_ZSH_ASYNC_PID
      name=off; [[ "$enabled" == 0 ]] || name=one
      for i in {1..200}; do [[ -s "$name.ready" ]] && break; sleep 0.05; done
      [[ -s "$name.ready" ]]
      lmline-zsh-generate-widget >/dev/null 2>&1
      [[ "$__LMLINE_ZSH_ASYNC_PID" == "$first_pid" ]]
      printf "private-uname-two\n" >output
      if [[ "$enabled" == 1 ]]; then
        [[ "$key" != "$(__lmline_zsh_request_key generate "# uname" 7)" ]]
      else
        [[ "$key" == "$(__lmline_zsh_request_key generate "# uname" 7)" && ! -e calls ]]
      fi
      lmline-zsh-generate-widget >/dev/null 2>&1
      second_pid=$__LMLINE_ZSH_ASYNC_PID
      [[ "$BUFFER" == "# uname" && ! -e uname-candidate-executed ]]
      if [[ "$enabled" == 1 ]]; then
        [[ "$second_pid" != "$first_pid" && -s one.stopped && ! -e one.finished ]]
        ! kill -0 "$first_pid" 2>/dev/null
        name=two
      else
        [[ "$second_pid" == "$first_pid" && ! -e calls ]]
      fi
      for i in {1..200}; do [[ -s "$name.ready" ]] && break; sleep 0.05; done
      [[ -s "$name.ready" ]]
      printf "release\n" >"$name.gate"
      wait "$second_pid"
      lmline-zsh-generate-widget >/dev/null 2>&1
      [[ "$BUFFER" == "touch uname-candidate-executed # $name" && ! -e uname-candidate-executed ]]
      [[ "$enabled" == 1 || ! -e calls ]]
    done
  ' _ "$repo_dir" || fail "zsh async uname context identity"
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
  LMLINE_CONFIG_DIR="$zsh_tmp/config-output" zsh -efic '
    source "$1/lmline/init.zsh"
    output_file="$2/bridge-output"
    status_file="$2/bridge-status"
    trap "rm -f \"$output_file\" \"$status_file\"" EXIT
    printf "ordinary diagnostic\nlmline-progress: progress\nlmline-meta: meta\nlmline-status: old\nlmline-search: search\nlmline-citation: citation\nlmline-status: m=zsh; tok=80/8/88\nlmline-candidate: low\tno risk\t-\techo one\nlast without newline" >"$output_file"
    __lmline_zsh_process_bridge_output "$output_file" "$status_file"
    [[ "$__LMLINE_ZSH_STATUS_LINE" == "m=zsh; tok=80/8/88" ]]
    expected_output=$(printf "ordinary diagnostic\nlmline-candidate: low\tno risk\t-\techo one\nlast without newline")
    [[ "$__LMLINE_ZSH_BRIDGE_OUTPUT" == "$expected_output" ]]
    printf "%b" "before\\0binary\nlmline-status: m=nul\nlmline-progress: hidden\nend\\0tail" >"$output_file"
    expected_status=$(awk "/^lmline-status: / { sub(/^lmline-status: /, \"\"); last=\$0 } END { print last }" "$output_file" 2>/dev/null)
    expected_output=$(sed "/^lmline-progress: /d; /^lmline-meta: /d; /^lmline-status: /d; /^lmline-search: /d; /^lmline-citation: /d" "$output_file" 2>/dev/null)
    __lmline_zsh_process_bridge_output "$output_file" "$status_file"
    [[ "$__LMLINE_ZSH_STATUS_LINE" == "$expected_status" && "$__LMLINE_ZSH_BRIDGE_OUTPUT" == "$expected_output" ]]
  ' _ "$repo_dir" "$zsh_tmp" || fail "zsh bridge output filtering"
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
    source "$1/lmline/init.zsh" || exit 84
    [[ " ${precmd_functions[@]} " == *"__lmline_zsh_async_prompt_check"* ]]
    source "$1/lmline/init.zsh" || exit 85
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
  LMLINE_CONFIG_DIR="$zsh_tmp/config-notify-revoked" zsh -efic '
    cfg=$2
    mkdir -p "$cfg" || exit 80
    unset LMLINE_ASYNC_NOTIFY
    printf "%s\n" "export LMLINE_ASYNC_NOTIFY=1" >"$cfg/settings.bash"
    source "$1/lmline/init.zsh"
    ready="$cfg/completed-result"
    tmp_out="$cfg/notify.out"
    trap "rm -f \"$ready\" \"$tmp_out\"" EXIT
    print -r -- candidate >"$ready"
    __LMLINE_ZSH_ASYNC_FILE=$ready
    __LMLINE_ZSH_ASYNC_PID=2147483647
    __LMLINE_ZSH_ASYNC_NOTIFIED=0
    printf "%s\n" "export LMLINE_ASYNC_NOTIFY=0" >"$cfg/settings.bash"
    __lmline_zsh_async_prompt_check 2>"$tmp_out"
    [[ "${LMLINE_ASYNC_NOTIFY:-}" == 0 && ! -s "$tmp_out" && \
      $__LMLINE_ZSH_ASYNC_NOTIFIED == 0 && \
      ${precmd_functions[(Ie)__lmline_zsh_async_prompt_check]} == 0 ]]
  ' _ "$repo_dir" "$zsh_tmp/config-notify-revoked" || fail "zsh async notify opt-out reload"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-notify-enabled" zsh -efic '
    cfg=$2
    mkdir -p "$cfg" || exit 81
    unset LMLINE_ASYNC_NOTIFY
    : >"$cfg/settings.bash"
    source "$1/lmline/init.zsh"
    [[ "${LMLINE_ASYNC_NOTIFY:-0}" == 0 && \
      ${precmd_functions[(Ie)__lmline_zsh_async_prompt_check]} == 0 ]] || exit 82
    printf "%s\n" "export LMLINE_ASYNC_NOTIFY=1" >"$cfg/settings.bash"
    __lmline_zsh_reload_settings_if_changed
    [[ "$LMLINE_ASYNC_NOTIFY" == 1 && \
      ${precmd_functions[(Ie)__lmline_zsh_async_prompt_check]} -gt 0 ]] || exit 83
    ready="$cfg/completed-result"
    tmp_out="$cfg/notify.out"
    trap "rm -f \"$ready\" \"$tmp_out\"" EXIT
    print -r -- candidate >"$ready"
    __LMLINE_ZSH_ASYNC_FILE=$ready
    __LMLINE_ZSH_ASYNC_PID=2147483647
    __LMLINE_ZSH_ASYNC_NOTIFIED=0
    __lmline_zsh_async_prompt_check 2>"$tmp_out"
    out=$(<"$tmp_out")
    [[ "$out" == *"suggestion ready"* && $__LMLINE_ZSH_ASYNC_NOTIFIED == 1 ]]
  ' _ "$repo_dir" "$zsh_tmp/config-notify-enabled" || fail "zsh async notify opt-in reload"
  rm -rf "$zsh_tmp"
  ok "zsh integration"
else
  printf 'skip - zsh integration (zsh not found)\n'
fi
