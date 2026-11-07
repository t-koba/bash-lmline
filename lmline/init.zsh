#!/usr/bin/env zsh

[[ -n "${ZSH_VERSION-}" ]] || return 0
[[ -o interactive ]] || return 0
setopt interactivecomments

typeset -g LMLINE_DIR=${0:A:h}
typeset -g LMLINE_CONFIG_DIR=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}

if ! command -v bash >/dev/null 2>&1 || ! bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) ))' 2>/dev/null; then
  print -ru2 -- 'lmline: zsh integration requires bash 4.2 or newer for the bridge.'
  return 0
fi

# Reload bookkeeping shared with the bash loader: which settings the last
# bridge load provided, so a later load can drop values the files no longer
# contain instead of leaving them stale. Baselines are captured before the
# first bridge load; per-key values live in double-underscore variables that
# config files cannot define.
(( ${+__LMLINE_ZSH_BASELINE_SET} )) || typeset -g __LMLINE_ZSH_BASELINE_SET=0
(( ${+__LMLINE_ZSH_BASELINE_KEYS} )) || typeset -g __LMLINE_ZSH_BASELINE_KEYS=
(( ${+__LMLINE_ZSH_BRIDGE_KEYS} )) || typeset -g __LMLINE_ZSH_BRIDGE_KEYS=

__lmline_zsh_key_in_list() {
  [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

__lmline_zsh_capture_env_baseline() {
  [[ "$__LMLINE_ZSH_BASELINE_SET" == 1 ]] && return 0
  __LMLINE_ZSH_BASELINE_SET=1
  local k
  local -a baseline_names
  # KSH_ARRAYS changes this special-parameter expansion; preserve its old path.
  if [[ -o KSH_ARRAYS ]]; then
    baseline_names=( "${(@k)parameters}" )
  else
    baseline_names=( "${(@k)parameters[(I)LMLINE_*]}" )
  fi
  for k in "${baseline_names[@]}"; do
    [[ "$k" =~ "^LMLINE_[A-Z0-9_]+$" ]] || continue
    __LMLINE_ZSH_BASELINE_KEYS+="$k"$'\n'
    typeset -g "__LMLINE_ZSHBASE_$k=${(P)k}"
  done
}

# Avoid a subprocess for private cleanup without changing `rm` lookup or any
# zsh/files features the user already loaded.
__lmline_zsh_remove_temp_file() {
  # zsh/files can be loaded with only a subset of its builtin features.
  local features module_was_loaded=0
  if features=$(builtin zmodload -L -F zsh/files 2>/dev/null); then
    module_was_loaded=1
  else
    features=
  fi
  if [[ " $features " == *" b:rm "* ]]; then
    builtin rm -f "$1" 2>/dev/null || command rm -f "$1"
  elif builtin zmodload -F zsh/files b:rm 2>/dev/null; then
    builtin rm -f "$1" 2>/dev/null || command rm -f "$1"
    if (( module_was_loaded )); then
      builtin zmodload -F zsh/files -b:rm 2>/dev/null || true
    else
      builtin zmodload -u zsh/files 2>/dev/null || true
    fi
  else
    command rm -f "$1"
  fi
}

__lmline_zsh_load_all_config() {
  local export_file key value new_keys old_keys cur stamp ref base uk
  local system_features feature export_fd export_path
  local -a system_restore
  local system_was_loaded=0 sysopen_available=1 anonymous_export=0
  local project_config_baseline_set=0 project_config_baseline_value=
  __lmline_zsh_capture_env_baseline
  old_keys=$__LMLINE_ZSH_BRIDGE_KEYS
  if __lmline_zsh_key_in_list "$__LMLINE_ZSH_BASELINE_KEYS" LMLINE_PROJECT_CONFIG; then
    base=__LMLINE_ZSHBASE_LMLINE_PROJECT_CONFIG
    project_config_baseline_set=1
    project_config_baseline_value=${(P)base}
  fi
  # Keep the exclusively created file open and unlink it before exporting any
  # values: a writable TMPDIR must not let pathname replacement redirect I/O.
  if system_features=$(builtin zmodload -L -F zsh/system 2>/dev/null); then
    system_was_loaded=1
  else
    system_features=
  fi
  {
    for feature in sysopen sysseek; do
      [[ " $system_features " == *" b:$feature "* ]] && continue
      if builtin zmodload -F zsh/system "b:$feature" 2>/dev/null; then
        system_restore+=("-b:$feature")
      else
        sysopen_available=0
        break
      fi
    done
    if (( sysopen_available )); then
      export_path="${TMPDIR:-/tmp}/lmline-zsh-config.$$"
      if builtin sysopen -r -w -o creat -o excl -m 600 -u export_fd "$export_path" 2>/dev/null; then
        export_file=$export_path
        anonymous_export=1
        __lmline_zsh_remove_temp_file "$export_file"
        [[ ! -e "$export_file" && ! -L "$export_file" ]] || return 1
      fi
    fi
    if (( ! anonymous_export )); then
      # Restore even a partially successful feature load before falling back.
      if (( ${#system_restore} )); then
        if (( system_was_loaded )); then
          builtin zmodload -F zsh/system "${system_restore[@]}" 2>/dev/null || true
        else
          builtin zmodload -u zsh/system 2>/dev/null || true
        fi
        system_restore=()
      fi
      export_file=$(mktemp "${TMPDIR:-/tmp}/lmline-zsh-config.XXXXXX") || return 1
      exec {export_fd}>"$export_file" || return 1
    fi
    if ! LMLINE_CONFIG_DIR="$LMLINE_CONFIG_DIR" \
      __LMLINE_ZSH_PREV_KEYS="$__LMLINE_ZSH_BRIDGE_KEYS" \
      __LMLINE_ZSH_PROJECT_CONFIG_BASELINE_SET="$project_config_baseline_set" \
      __LMLINE_ZSH_PROJECT_CONFIG_BASELINE_VALUE="$project_config_baseline_value" bash -c '
      source "$1/config.bash"
      __lmline_forget_bridge_keys
      if [[ "${__LMLINE_ZSH_PROJECT_CONFIG_BASELINE_SET:-0}" == 1 ]]; then
        printf -v LMLINE_PROJECT_CONFIG "%s" "${__LMLINE_ZSH_PROJECT_CONFIG_BASELINE_VALUE-}"
        export LMLINE_PROJECT_CONFIG
      fi
      __lmline_load_all_config
      while IFS= read -r key; do
        [[ "$key" =~ ^LMLINE_[A-Z0-9_]*$ ]] || continue
        printf "%s\0%s\0" "$key" "${!key}"
      done < <(compgen -e LMLINE_)
    ' _ "$LMLINE_DIR" >&$export_fd; then
      return 1
    fi
    if (( anonymous_export )); then
      builtin sysseek -u $export_fd 0 || return 1
    else
      exec {export_fd}>&-
      export_fd=
      exec {export_fd}<"$export_file" || return 1
    fi
    new_keys=
    while IFS= read -r -d "" -u $export_fd key && IFS= read -r -d "" -u $export_fd value; do
      typeset -gx "$key=$value"
      new_keys+="$key"$'\n'
      typeset -g "__LMLINE_ZSHSTAMP_$key=${(P)key}"
    done
  } always {
    [[ -z "$export_fd" ]] || exec {export_fd}>&-
    [[ -z "$export_file" ]] || __lmline_zsh_remove_temp_file "$export_file"
    if (( ${#system_restore} )); then
      if (( system_was_loaded )); then
        builtin zmodload -F zsh/system "${system_restore[@]}" 2>/dev/null || true
      else
        builtin zmodload -u zsh/system 2>/dev/null || true
      fi
    fi
  }
  # Drop values the files no longer define: restore the pre-bridge
  # environment value (or unset), but only while the shell still holds the
  # value the bridge provided, so intentional user changes are never cleared.
  for uk in ${(f)old_keys}; do
    [[ -n "$uk" ]] || continue
    __lmline_zsh_key_in_list "$new_keys" "$uk" && continue
    ref=__LMLINE_ZSHSTAMP_$uk
    if (( ${+parameters[$uk]} )); then cur=${(P)uk}; else cur=$'\001UNSET\001'; fi
    stamp=${(P)ref}
    if [[ "$cur" == "$stamp" ]]; then
      if __lmline_zsh_key_in_list "$__LMLINE_ZSH_BASELINE_KEYS" "$uk"; then
        base=__LMLINE_ZSHBASE_$uk
        typeset -gx "$uk=${(P)base}"
      else
        unset "$uk"
      fi
    fi
    unset "__LMLINE_ZSHSTAMP_$uk"
  done
  __LMLINE_ZSH_BRIDGE_KEYS=$new_keys
}

typeset -g __LMLINE_ZSH_SETTINGS_CKSUM=

# Keep the opt-in prompt hook synchronized with reloaded interactive settings.
__lmline_zsh_sync_async_notify_hook() {
  typeset -ga precmd_functions
  if [[ "${LMLINE_ASYNC_NOTIFY:-0}" == 1 ]]; then
    if (( ${precmd_functions[(Ie)__lmline_zsh_async_prompt_check]} == 0 )); then
      precmd_functions+=(__lmline_zsh_async_prompt_check)
    fi
  else
    precmd_functions=(${precmd_functions:#__lmline_zsh_async_prompt_check})
  fi
  return 0
}

# Mirrors __lmline_reload_settings_if_changed for the zsh environment: re-exports
# settings.bash values when the file content changed, so "lmline config set"
# applies to the next widget invocation without restarting the shell. Content
# identity (not second-precision mtimes) catches same-second replacements.
__lmline_zsh_reload_settings_if_changed() {
  local file=$LMLINE_CONFIG_DIR/settings.bash sum
  if [[ -f "$file" ]]; then
    sum=$(cksum <"$file" 2>/dev/null) || sum=
    [[ -n "$sum" ]] || return 0
  else
    # A deleted file is also a change: reload so file-owned values are dropped.
    sum="no-settings-file"
  fi
  if [[ "$sum" == "$__LMLINE_ZSH_SETTINGS_CKSUM" ]]; then
    __lmline_zsh_sync_async_notify_hook
    return 0
  fi
  __LMLINE_ZSH_SETTINGS_CKSUM=$sum
  __lmline_zsh_load_all_config
  __lmline_zsh_sync_async_notify_hook
  return 0
}

# Prime before loading; the post-load check still catches startup changes.
if [[ -f "$LMLINE_CONFIG_DIR/settings.bash" ]]; then
  __LMLINE_ZSH_SETTINGS_CKSUM=$(cksum <"$LMLINE_CONFIG_DIR/settings.bash" 2>/dev/null) || __LMLINE_ZSH_SETTINGS_CKSUM=
else
  __LMLINE_ZSH_SETTINGS_CKSUM=no-settings-file
fi
__lmline_zsh_load_all_config
__lmline_zsh_reload_settings_if_changed

typeset -g LMLINE_ENGINE=${LMLINE_ENGINE:-$LMLINE_DIR/engine}
typeset -g LMLINE_HISTORY_DIR=${LMLINE_HISTORY_DIR:-$LMLINE_CONFIG_DIR/history}
typeset -g LMLINE_STATUS_MODE=${LMLINE_STATUS_MODE:-inline}
typeset -g LMLINE_SPINNER=${LMLINE_SPINNER:-1}
typeset -g LMLINE_SPINNER_INTERVAL=${LMLINE_SPINNER_INTERVAL:-0.2}
typeset -g LMLINE_KEY_GENERATE=${LMLINE_KEY_GENERATE:-'^X^G'}
typeset -g LMLINE_KEY_REWRITE=${LMLINE_KEY_REWRITE:-'^X^R'}
typeset -g LMLINE_KEY_NEXT=${LMLINE_KEY_NEXT:-'^X^N'}
typeset -g LMLINE_KEY_PREV=${LMLINE_KEY_PREV:-'^X^P'}
typeset -g LMLINE_KEY_EXPLAIN=${LMLINE_KEY_EXPLAIN:-'^X^E'}
typeset -g LMLINE_KEY_FIX=${LMLINE_KEY_FIX:-'^X^F'}
typeset -g LMLINE_KEY_CLIP=${LMLINE_KEY_CLIP:-'^X^V'}
typeset -g LMLINE_FIX_TIMEOUT=${LMLINE_FIX_TIMEOUT:-12}
typeset -g LMLINE_FIX_MAX_OUTPUT=${LMLINE_FIX_MAX_OUTPUT:-12000}
typeset -g LMLINE_FIX_ALLOW_MEDIUM=${LMLINE_FIX_ALLOW_MEDIUM:-0}
typeset -g LMLINE_ASYNC=${LMLINE_ASYNC:-0}
typeset -g LMLINE_CANDIDATE_COUNT=${LMLINE_CANDIDATE_COUNT:-3}
typeset -g LMLINE_REWRITE_BACKEND=${LMLINE_REWRITE_BACKEND:-engine}
typeset -g LMLINE_GENERATE_BACKEND=${LMLINE_GENERATE_BACKEND:-engine}
typeset -g LMLINE_FIX_BACKEND=${LMLINE_FIX_BACKEND:-engine}
typeset -g LMLINE_PS0=${LMLINE_PS0:-'🍋‍🟩 '}

typeset -ga __LMLINE_ZSH_CANDIDATES
typeset -ga __LMLINE_ZSH_RISKS
typeset -ga __LMLINE_ZSH_REASONS
typeset -ga __LMLINE_ZSH_FLAGS
typeset -gi __LMLINE_ZSH_INDEX=1
typeset -g __LMLINE_ZSH_LAST_ORIGINAL=
typeset -g __LMLINE_ZSH_LAST_MODE=
typeset -g __LMLINE_ZSH_LAST_SUGGESTION_ID=
(( ${+__LMLINE_ZSH_ASYNC_KEY} )) || typeset -g __LMLINE_ZSH_ASYNC_KEY=
(( ${+__LMLINE_ZSH_ASYNC_FILE} )) || typeset -g __LMLINE_ZSH_ASYNC_FILE=
(( ${+__LMLINE_ZSH_ASYNC_PID} )) || typeset -gi __LMLINE_ZSH_ASYNC_PID=0
(( ${+__LMLINE_ZSH_ASYNC_STARTED} )) || typeset -gi __LMLINE_ZSH_ASYNC_STARTED=0
(( ${+__LMLINE_ZSH_ASYNC_NOTIFIED} )) || typeset -gi __LMLINE_ZSH_ASYNC_NOTIFIED=0
typeset -gi __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
typeset -g __LMLINE_ZSH_STATUS_LINE=

__lmline_zsh_async_cleanup() {
  [[ -n "${__LMLINE_ZSH_ASYNC_FILE:-}" ]] || return 0
  if (( __LMLINE_ZSH_ASYNC_PID > 0 )) && kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null; then
    kill -TERM "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null || true
    wait "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null || true
  fi
  rm -f "$__LMLINE_ZSH_ASYNC_FILE" "$__LMLINE_ZSH_ASYNC_FILE.status" "$__LMLINE_ZSH_ASYNC_FILE.status.err" "$__LMLINE_ZSH_ASYNC_FILE.tmp."*(N)
  __LMLINE_ZSH_ASYNC_FILE=
  __LMLINE_ZSH_ASYNC_PID=0
  __LMLINE_ZSH_ASYNC_KEY=
}

__lmline_zsh_hint() {
  case "$LMLINE_STATUS_MODE" in
    log|debug) print -ru2 -- "$1" ;;
    silent|none) ;;
    *)
      if zle -M -- "$1" 2>/dev/null; then
        return 0
      fi
      print -nru2 -- $'\r\e[K'"$1"
      ;;
  esac
}

__lmline_zsh_clear_hint() {
  case "$LMLINE_STATUS_MODE" in
    log|debug|silent|none) ;;
    *)
      if zle -M -- "" 2>/dev/null; then
        return 0
      fi
      print -nru2 -- $'\r\e[K'
      ;;
  esac
}

__lmline_zsh_spinner_enabled() {
  [[ "$LMLINE_SPINNER" == 1 && -t 2 ]] || return 1
  case "$LMLINE_STATUS_MODE" in
    inline|transient) return 0 ;;
    *) return 1 ;;
  esac
}

__lmline_zsh_progress_label() {
  local file=$1 fallback=$2 label
  if [[ -f "$file" ]]; then
    label=$(awk '/^lmline-progress: / { sub(/^lmline-progress: /, ""); last=$0 } END { print last }' "$file" 2>/dev/null)
  fi
  print -nr -- "${label:-$fallback}"
}

# The engine emits one preformatted "lmline-status:" line; display it verbatim.
__lmline_zsh_read_meta() {
  local file=$1
  __LMLINE_ZSH_STATUS_LINE=
  [[ -f "$file" ]] || return 0
  __LMLINE_ZSH_STATUS_LINE=$(awk '/^lmline-status: / { sub(/^lmline-status: /, ""); last=$0 } END { print last }' "$file" 2>/dev/null)
}

__lmline_zsh_strip_progress_lines() {
  sed '/^lmline-progress: /d; /^lmline-meta: /d; /^lmline-status: /d; /^lmline-search: /d; /^lmline-citation: /d'
}

# The Darwin combined AWK path fails the bridge byte-parity test, so retain the
# original status-extraction and sed-filtering path there.
__lmline_zsh_process_bridge_output() {
  local file=$1 status_file=$2
  __LMLINE_ZSH_STATUS_LINE=
  __LMLINE_ZSH_BRIDGE_OUTPUT=
  [[ -f "$file" ]] || return 0
  if [[ "$OSTYPE" == darwin* ]]; then
    __lmline_zsh_read_meta "$file"
    __LMLINE_ZSH_BRIDGE_OUTPUT=$(__lmline_zsh_strip_progress_lines <"$file" 2>/dev/null)
    return 0
  fi
  __LMLINE_ZSH_BRIDGE_OUTPUT=$(LMLINE_ZSH_STATUS_FILE="$status_file" awk '
    /^lmline-status: / { sub(/^lmline-status: /, ""); last=$0; next }
    /^lmline-progress: / || /^lmline-meta: / || /^lmline-search: / || /^lmline-citation: / { next }
    { print }
    END { printf "%s", last > ENVIRON["LMLINE_ZSH_STATUS_FILE"] }
  ' "$file" 2>/dev/null)
  IFS= read -r __LMLINE_ZSH_STATUS_LINE <"$status_file" || :
}

__lmline_zsh_meta_status() {
  print -nr -- "$__LMLINE_ZSH_STATUS_LINE"
}

# Parses "lmline-candidate:" protocol lines into the candidate arrays. The
# engine owns validation and risk classification.
__lmline_zsh_set_candidates() {
  local output=$1 payload risk reason flags candidate rest
  # Zsh needs byte matching as well as the C locale; restore options on return.
  setopt localoptions nomultibyte
  local LC_ALL=C
  __LMLINE_ZSH_CANDIDATES=()
  __LMLINE_ZSH_RISKS=()
  __LMLINE_ZSH_REASONS=()
  __LMLINE_ZSH_FLAGS=()
  for payload in "${(@f)output}"; do
    [[ "$payload" == 'lmline-candidate: '* ]] || continue
    payload=${payload#lmline-candidate: }
    risk=${payload%%$'\t'*}; rest=${payload#*$'\t'}
    reason=${rest%%$'\t'*}; rest=${rest#*$'\t'}
    flags=${rest%%$'\t'*}; candidate=${rest#*$'\t'}
    [[ -n "$candidate" ]] || continue
    # C1 is C2 80..9F in UTF-8; bare continuation bytes are not controls.
    [[ "$candidate" != *$'\302'[$'\200'-$'\237']* ]] || continue
    # Unicode Bidi_Control: U+061C, U+200E/U+200F, U+202A-U+202E, U+2066-U+2069.
    [[ "$candidate" != *$'\330\234'* ]] || continue
    [[ "$candidate" != *$'\342\200'[$'\216'-$'\217'$'\252'-$'\256']* ]] || continue
    [[ "$candidate" != *$'\342\201'[$'\246'-$'\251']* ]] || continue
    [[ "$candidate" != *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']* ]] || continue
    case "$risk" in
      high|medium|low) ;;
      *) risk=high; reason='unknown risk annotation' ;;
    esac
    (( ${__LMLINE_ZSH_CANDIDATES[(Ie)$candidate]} )) && continue
    __LMLINE_ZSH_CANDIDATES+=("$candidate")
    __LMLINE_ZSH_RISKS+=("$risk")
    __LMLINE_ZSH_REASONS+=("$reason")
    __LMLINE_ZSH_FLAGS+=("${flags:--}")
  done
}

__lmline_zsh_wait_with_spinner() {
  local pid=$1 label=$2 progress_file=${3:-} frame_index=1 tick=0 elapsed=0 interval=${LMLINE_SPINNER_INTERVAL:-0.2} current_label wait_status=0
  local progress_fd= guard_fd= line partial= last_label=
  local -a frames=('.  ' '.. ' '...')
  if ! __lmline_zsh_spinner_enabled; then
    wait "$pid" || wait_status=$?
    return "$wait_status"
  fi
  # Only regular engine logs can be drained without blocking. Keep independent
  # offsets because line reads may discard NULs and change prefix matching.
  if [[ -f "$progress_file" ]]; then
    { exec {progress_fd}<"$progress_file"; } 2>/dev/null || progress_fd=
    if [[ -n "$progress_fd" ]]; then
      { exec {guard_fd}<"$progress_file"; } 2>/dev/null || {
        exec {progress_fd}<&-
        progress_fd=
      }
    fi
  fi
  while kill -0 "$pid" 2>/dev/null; do
    if [[ -n "$progress_fd" ]]; then
      while IFS= read -r -u "$progress_fd" line; do
        line=$partial$line
        partial=
        [[ "$line" == 'lmline-progress: '* ]] && last_label=${line#lmline-progress: }
      done
      partial=$partial$line
      # Check after draining so a concurrent append cannot hide a NUL in the
      # bytes just read. Once found, retain awk's exact binary-file semantics.
      if IFS= read -r -d '' -u "$guard_fd" line; then
        line=
        exec {progress_fd}<&- {guard_fd}<&-
        progress_fd=
      else
        line=
        current_label=$last_label
        [[ "$partial" == 'lmline-progress: '* ]] && current_label=${partial#lmline-progress: }
        current_label=${current_label:-$label}
      fi
    fi
    if [[ -z "$progress_fd" ]]; then
      current_label=$(__lmline_zsh_progress_label "$progress_file" "$label")
    fi
    __lmline_zsh_hint "${LMLINE_PS0}${current_label}${frames[$frame_index]} ${elapsed}s"
    sleep "$interval"
    frame_index=$(( (frame_index % ${#frames[@]}) + 1 ))
    tick=$((tick + 1))
    (( tick % 5 == 0 )) && elapsed=$((elapsed + 1))
  done
  [[ -n "$progress_fd" ]] && exec {progress_fd}<&- {guard_fd}<&-
  wait "$pid" || wait_status=$?
  return "$wait_status"
}

__lmline_zsh_engine_hint() {
  local output=$1
  output=$(LMLINE_CONFIG_DIR=$LMLINE_CONFIG_DIR bash -c '
    source "$1/context.bash"
    source "$1/actions.bash"
    __lmline_engine_error_message "$2" "$3"
  ' _ "$LMLINE_DIR" "$LMLINE_PS0" "${output[1,200]}")
  print -nr -- "${output%$'\n'}"
}

__lmline_zsh_mode() {
  print -r -- generate
}

__lmline_zsh_run_bridge() {
  local label=$1 action=$2 mode=$3 line=$4 point=$5 tmp output_file pid had_monitor=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-zsh.XXXXXX") || return 1
  output_file=$tmp/output
  if [[ -o monitor ]]; then
    had_monitor=1
    unsetopt monitor
  fi
  { __lmline_zsh_bridge "$action" "$mode" "$line" "$point" >"$output_file" 2>&1 & pid=$!; } 2>/dev/null
  __LMLINE_ZSH_BRIDGE_STATUS=0
  __lmline_zsh_wait_with_spinner "$pid" "$label" "$output_file" || __LMLINE_ZSH_BRIDGE_STATUS=$?
  __lmline_zsh_clear_hint
  __lmline_zsh_process_bridge_output "$output_file" "$tmp/status"
  (( had_monitor == 1 )) && setopt monitor
  rm -rf "$tmp"
  return "$__LMLINE_ZSH_BRIDGE_STATUS"
}

__lmline_zsh_bridge() {
  local action=$1 mode=${2-} line=${3-} point=${4-0} async_file=${5-} key declaration caller_functions
  local -a bridge_command
  # Only the background async invocation may replace its Zsh subshell.
  bridge_command=(command)
  [[ -z "$async_file" ]] || bridge_command=(exec)
  local -a bridge_env bridge_env_unset bridge_env_set
  # The bridge runs in Bash, but zsh session settings are often globals that
  # were never exported. Pass those values for this invocation without
  # exporting them permanently or carrying function-local bookkeeping into
  # the child.
  for key in ${(k)parameters}; do
    [[ "$key" =~ "^LMLINE_[A-Z0-9_]+$" ]] || continue
    bridge_env_unset+=(-u "$key")
    [[ "${parameters[$key]}" == scalar || "${parameters[$key]}" == scalar-export ]] || continue
    declaration=$(typeset -p "$key" 2>/dev/null) || continue
    [[ "$declaration" == "typeset -g "* || "$declaration" == "export "* ]] || continue
    bridge_env_set+=("$key=${(P)key}")
  done
  # The parent zsh has already loaded the current config hierarchy. Seed the
  # child's reload identity so it does not re-apply settings files over a
  # session value that the user changed after that load.
  bridge_env=("${bridge_env_unset[@]}" "${bridge_env_set[@]}" "__LMLINE_SETTINGS_CKSUM=$__LMLINE_ZSH_SETTINGS_CKSUM")
  # Caller-shell function names only (never bodies), carried into the Bash
  # child only to be snapshotted and unset there before sourcing context.
  # The child passes them only on its engine command for this (zsh) target;
  # context and Copilot subprocesses never inherit them, while same-process
  # Copilot validation still sees the non-exported snapshot.
  caller_functions=$(print -l -- ${(ok)functions} 2>/dev/null) || caller_functions=
  bridge_env+=("LMLINE_SHELL_FUNCTIONS=${caller_functions}")
  "${bridge_command[@]}" env "${bridge_env[@]}" bash -p -c '
    __lmline_bridge_main() {
      set -u
      set -o pipefail
      __LMLINE_CALLER_FUNCTIONS=${LMLINE_SHELL_FUNCTIONS-}
      __LMLINE_EXPORTED_FUNCTIONS=
      export -n __LMLINE_CALLER_FUNCTIONS __LMLINE_EXPORTED_FUNCTIONS 2>/dev/null || true
      unset LMLINE_SHELL_FUNCTIONS LMLINE_EXPORTED_FUNCTIONS
      source "$LMLINE_DIR/context.bash"
      source "$LMLINE_DIR/policy.bash"
      source "$LMLINE_DIR/actions.bash"
      case "$1" in
        generate)
          mode=$2
          line=$3
          point=$4
          tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-zsh.XXXXXX")
          trap "rm -rf \"$tmp\"" EXIT
          engine_file="$tmp/engine"
          status=0
          if { [[ "$mode" == rewrite && "${LMLINE_REWRITE_BACKEND:-engine}" == copilot ]] ||
               [[ "$mode" == generate && "${LMLINE_GENERATE_BACKEND:-engine}" == copilot ]]; }; then
            __lmline_copilot_candidates "$line" "$point" zsh "$mode" >"$engine_file" || status=$?
          else
            printf "%s" "$line" >"$tmp/line"
            __lmline_context_file "$tmp/context" "$line" "$mode"
            LMLINE_SHELL_FUNCTIONS="$__LMLINE_CALLER_FUNCTIONS" LMLINE_EXPORTED_FUNCTIONS="$__LMLINE_EXPORTED_FUNCTIONS" "$LMLINE_ENGINE" --mode "$mode" --shell zsh --cwd "$PWD" --point "$point" --line-file "$tmp/line" --context-file "$tmp/context" --n "$LMLINE_CANDIDATE_COUNT" >"$engine_file" || status=$?
          fi
          grep "^lmline-candidate: " "$engine_file" || true
          if [[ "$status" == 0 && "$mode" == rewrite ]]; then
            printf "lmline-candidate: low\t-\toriginal\t%s\n" "$line"
          fi
          exit "$status"
          ;;
        risk)
          printf "%s\t%s\n" "$(__lmline_risk_level "$3")" "$(__lmline_risk_reason "$3")"
          ;;
        explain)
          line=$3
          point=$4
          __lmline_print_explanation "$LMLINE_ENGINE" zsh "$line" "$point" "$LMLINE_PS0"
          ;;
        clip)
          __lmline_print_clip "$LMLINE_ENGINE" zsh "" "$LMLINE_PS0"
          ;;
        fix)
          line=$3
          point=$4
          __lmline_fix_run "$line" zsh "$point" "$LMLINE_ENGINE" "$LMLINE_CANDIDATE_COUNT" "$LMLINE_PS0"
          ;;
      esac
    }
    # Zsh cannot enable job control without a terminal. This Bash supervisor
    # owns a worker group even there; exec preserves the tracked request PID.
    if [[ -n "$5" ]]; then
      async_file=$5
      tmp_out=$async_file.tmp.$$
      set -m 2>/dev/null
      worker=0 cancelled=0
      __lmline_cancel_worker() {
        cancelled=1
        if (( worker > 0 )); then
          kill -TERM -- "-$worker" 2>/dev/null || true
          wait "$worker" 2>/dev/null || true
          exit 143
        fi
      }
      trap __lmline_cancel_worker TERM
      ( set +m; __lmline_bridge_main "$@" ) >"$tmp_out" 2>"$async_file.status.err" &
      worker=$!
      (( cancelled == 0 )) || __lmline_cancel_worker
      if wait "$worker" && [[ -s "$tmp_out" ]]; then
        if mv "$tmp_out" "$async_file" 2>/dev/null; then
          printf "ok\n" >"$async_file.status"
        else
          rm -f "$tmp_out" "$async_file"
          printf "lmline-engine: async result publication failed\n" >"$async_file.status.err"
          printf "failed\n" >"$async_file.status"
        fi
      else
        rm -f "$tmp_out" "$async_file"
        printf "failed\n" >"$async_file.status"
      fi
      exit
    fi
    __lmline_bridge_main "$@"
  ' _ "$action" "$mode" "$line" "$point" "$async_file"
}

# One hardened Bash pass for the request identity. Private values and caller
# function names (never bodies) travel only on stdin, with explicit framing.
# Component entry points below share this path for focused identity checks.
__lmline_zsh_identity_key() {
  local action=$1 mode=${2-} line=${3-} point=${4-} key caller_functions
  setopt localoptions pipefail
  caller_functions=$(print -l -- ${(ok)functions} 2>/dev/null) || caller_functions=
  {
    # Preserve logical PWD even if Bash resets it after a directory rename.
    printf '%s\0' "$PWD" "${+PATH}" "${PATH-}" "$caller_functions" "${LMLINE_PROMPT_VERSION:-3}"
    # The parameter type includes "local" for dynamically scoped locals, so
    # these exact types select global scalars without a child per declaration.
    for key in ${(ok)parameters}; do
      [[ "$key" =~ "^LMLINE_[A-Z0-9_]+$" ]] || continue
      [[ "$key" == LMLINE_SHELL_FUNCTIONS || "$key" == LMLINE_EXPORTED_FUNCTIONS ]] && continue
      [[ "${parameters[$key]}" == scalar || "${parameters[$key]}" == scalar-export ]] || continue
      printf '%s\0%s\0' "$key" "${(P)key}"
    done
    printf '\0'
  } | bash -p -c '
    set -o pipefail
    IFS= read -r -d "" logical_pwd &&
      IFS= read -r -d "" path_set && IFS= read -r -d "" caller_path &&
      IFS= read -r -d "" caller_functions && IFS= read -r -d "" prompt_version || exit 1
    settings=()
    while :; do
      IFS= read -r -d "" key || exit 1
      [[ -n "$key" ]] || break
      [[ "$key" =~ ^LMLINE_[A-Z0-9_]+$ ]] || exit 1
      IFS= read -r -d "" value || exit 1
      settings+=("$key" "$value")
    done
    unset LMLINE_CONFIG_DIR LMLINE_USER_RULES_DIR LMLINE_DEFAULTS_DIR \
      LMLINE_SUGGESTED_COMMANDS_FILE LMLINE_INCLUDE_SUGGESTED_COMMANDS \
      LMLINE_PROJECT_MARKERS_FILE LMLINE_INCLUDE_PROJECT_CONTEXT \
      LMLINE_INCLUDE_GIT_CONTEXT LMLINE_INCLUDE_CWD_CONTEXT LMLINE_INCLUDE_SHELL_CONTEXT
    # Retain the settings digest format, including both cksum fields on
    # systems without SHA tools. Hash before context supplies any defaults.
    if [[ "$2" == settings || "$2" == request ]]; then
      settings_key=$(
        { if (( ${#settings[@]} )); then printf "%s\0" "${settings[@]}"; fi; } |
          { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d " " -f 1
            elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d " " -f 1
            elif command -v cksum >/dev/null 2>&1; then cksum
            else exit 1; fi; }
      ) || exit 1
      [[ -n "$settings_key" ]] || exit 1
      [[ "$2" != settings ]] || { printf "%s" "$settings_key"; exit; }
    fi
    # Only these inputs were passed to the component helpers. Leave other
    # inherited settings alone; never export the streamed private snapshot.
    for ((i=0; i<${#settings[@]}; i+=2)); do
      key=${settings[i]}
      case "$key" in
        LMLINE_CONFIG_DIR|LMLINE_USER_RULES_DIR|LMLINE_DEFAULTS_DIR|\
        LMLINE_SUGGESTED_COMMANDS_FILE|LMLINE_INCLUDE_SUGGESTED_COMMANDS|\
        LMLINE_PROJECT_MARKERS_FILE|LMLINE_INCLUDE_PROJECT_CONTEXT|\
        LMLINE_INCLUDE_GIT_CONTEXT|LMLINE_INCLUDE_CWD_CONTEXT|LMLINE_INCLUDE_SHELL_CONTEXT)
          printf -v "$key" "%s" "${settings[i+1]}" ;;
      esac
    done
    PWD=$logical_pwd
    LMLINE_PROMPT_VERSION=$prompt_version
    source "$1/context.bash" || exit 1
    case "$2" in
      suggested) __lmline_suggested_commands_key; exit $? ;;
      project) __lmline_project_markers_key; exit $? ;;
      git) __lmline_git_context_key; exit $? ;;
    esac
    path_key=$(
      { if [[ "$path_set" == 1 ]]; then printf "set\0%s\0" "$caller_path"; else printf "unset\0"; fi; } |
        __lmline_hash_stdin
    ) || exit 1
    [[ -n "$path_key" ]] || exit 1
    [[ "$2" != path ]] || { printf "%s" "$path_key"; exit; }
    suggested_key=$(__lmline_suggested_commands_key) && [[ -n "$suggested_key" ]] || exit 1
    project_key=$(__lmline_project_markers_key) && [[ -n "$project_key" ]] || exit 1
    git_key=$(__lmline_git_context_key) && [[ -n "$git_key" ]] || exit 1
    function_key=$(printf "%s\n" "$caller_functions" | __lmline_hash_stdin) || exit 1
    request_key=$(__lmline_request_key "$3" "$4") || exit 1
    [[ -n "$request_key" && -n "$function_key" ]] || exit 1
    printf "%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n" "$request_key" "$function_key" "$5" "$6" "$7" \
      "$settings_key" "$suggested_key" "$project_key" "$git_key" "$path_key"
  ' _ "$LMLINE_DIR" "$action" "$mode" "$line" "$point" "$__LMLINE_ZSH_SETTINGS_CKSUM" "${LMLINE_CANDIDATE_COUNT-}"
}

__lmline_zsh_settings_key() { __lmline_zsh_identity_key settings; }
__lmline_zsh_suggested_commands_key() { __lmline_zsh_identity_key suggested; }
__lmline_zsh_project_markers_key() { __lmline_zsh_identity_key project; }
__lmline_zsh_git_context_key() { __lmline_zsh_identity_key git; }
__lmline_zsh_path_key() { __lmline_zsh_identity_key path; }
__lmline_zsh_request_key() { __lmline_zsh_identity_key request "$@"; }

__lmline_zsh_load_candidates_from_file() {
  local file=$1 output
  output=$(cat "$file" 2>/dev/null)
  __lmline_zsh_set_candidates "$output"
}

__lmline_zsh_async_start() {
  local mode=$1 line=$2 point=$3 async_file=$4 key=${5-}
  __lmline_zsh_async_cleanup
  rm -f "$async_file.status" "$async_file.status.err" "$async_file"
  __lmline_zsh_bridge generate "$mode" "$line" "$point" "$async_file" &
  __LMLINE_ZSH_ASYNC_PID=$!
  # Keep this child waitable: cleanup must reap its supervisor before removing
  # request files. A numeric argument to disown is a job number, not this PID.
  if [[ -n "$key" ]]; then
    __LMLINE_ZSH_ASYNC_KEY=$key
  else
    __LMLINE_ZSH_ASYNC_KEY="request-key-unavailable:$__LMLINE_ZSH_ASYNC_PID"
  fi
  __LMLINE_ZSH_ASYNC_FILE=$async_file
  __LMLINE_ZSH_ASYNC_STARTED=$(date +%s)
  __LMLINE_ZSH_ASYNC_NOTIFIED=0
}

# Opt-in precmd hook (LMLINE_ASYNC_NOTIFY=1): announces once, at the next
# prompt, that a background generation finished and which key inserts it.
__lmline_zsh_async_prompt_check() {
  __lmline_zsh_reload_settings_if_changed
  [[ "${LMLINE_ASYNC_NOTIFY:-0}" == 1 ]] || return 0
  [[ -n "${__LMLINE_ZSH_ASYNC_FILE:-}" && ${__LMLINE_ZSH_ASYNC_PID:-0} -gt 0 ]] || return 0
  (( __LMLINE_ZSH_ASYNC_NOTIFIED == 0 )) || return 0
  kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null && return 0
  if [[ -s "$__LMLINE_ZSH_ASYNC_FILE" ]]; then
    __LMLINE_ZSH_ASYNC_NOTIFIED=1
    print -u2 -r -- "${LMLINE_PS0}suggestion ready; press ${LMLINE_KEY_GENERATE:-^X^G} to insert"
  fi
  return 0
}

__lmline_zsh_generate_async() {
  local original=$1 mode=$2 point=$3 async_file current_key async_status_file err_msg
  current_key=$(__lmline_zsh_request_key "$mode" "$original" "$point") || current_key=

  if [[ -n "$current_key" && "$__LMLINE_ZSH_ASYNC_KEY" == "$current_key" && $__LMLINE_ZSH_ASYNC_PID -gt 0 ]]; then
    async_file=$__LMLINE_ZSH_ASYNC_FILE
    if kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null; then
      local async_elapsed=$(( $(date +%s) - __LMLINE_ZSH_ASYNC_STARTED ))
      if (( __LMLINE_ZSH_ASYNC_STARTED > 0 && async_elapsed > ${LMLINE_ENGINE_TIMEOUT:-60} + 5 )); then
        __lmline_zsh_hint "${LMLINE_PS0}[$mode] async generation timed out (${async_elapsed}s)"
        __lmline_zsh_async_cleanup
        zle redisplay 2>/dev/null || true
        return 0
      fi
      __lmline_zsh_hint "${LMLINE_PS0}[$mode] still generating (${async_elapsed}s)..."
      zle redisplay 2>/dev/null || true
      return 0
    fi
    if [[ -s "$async_file" ]]; then
      __lmline_zsh_clear_hint
      __lmline_zsh_read_meta "$async_file.status.err"
      __lmline_zsh_load_candidates_from_file "$async_file"
      __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=1
      __lmline_zsh_apply_index 1
      __lmline_zsh_async_cleanup
      return 0
    fi
    if [[ -f "$async_file.status.err" ]]; then
      err_msg=$(LC_ALL=C cut -c 1-300 "$async_file.status.err")
      __lmline_zsh_hint "$(__lmline_zsh_engine_hint "$err_msg")"
    else
      __lmline_zsh_hint "${LMLINE_PS0}generation failed"
    fi
    __lmline_zsh_async_cleanup
    zle redisplay 2>/dev/null || true
    return 0
  fi

  async_file=$(mktemp "${TMPDIR:-/tmp}/lmline-zsh-async.XXXXXX") || {
    __lmline_zsh_hint "${LMLINE_PS0}async temp file failed"
    zle redisplay 2>/dev/null || true
    return 0
  }
  __lmline_zsh_async_start "$mode" "$original" "$point" "$async_file" "$current_key"
  __lmline_zsh_hint "${LMLINE_PS0}[$mode] generating in background; press the same key to insert when ready"
  zle redisplay 2>/dev/null || true
}

__lmline_zsh_record_suggestion() {
  local mode=$1 original=$2 candidate=$3 id timestamp
  id=$(date -u +%Y%m%d%H%M%S 2>/dev/null || print '0')-$$
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || print 'unknown')
  __LMLINE_ZSH_LAST_SUGGESTION_ID=$id
  # The log holds the user's own command lines, so it stays user-only.
  command mkdir -p "$LMLINE_HISTORY_DIR" 2>/dev/null || return 0
  command chmod 700 "$LMLINE_HISTORY_DIR" 2>/dev/null || true
  {
    print "id=${(q)id}"
    print "timestamp=${(q)timestamp}"
    print "cwd=${(q)PWD}"
    print "mode=${(q)mode}"
    print "original=${(q)original}"
    print "candidate=${(q)candidate}"
  } >>"$LMLINE_HISTORY_DIR/suggestions.log" 2>/dev/null || true
  command chmod 600 "$LMLINE_HISTORY_DIR/suggestions.log" 2>/dev/null || true
}

# Applies the candidate at the given index using the engine's risk/flag
# annotations; no per-apply risk bridge call.
__lmline_zsh_apply_index() {
  local index=$1
  __LMLINE_ZSH_INDEX=$index
  local candidate=${__LMLINE_ZSH_CANDIDATES[$index]}
  local risk=${__LMLINE_ZSH_RISKS[$index]:-high}
  local reason=${__LMLINE_ZSH_REASONS[$index]:--}
  local flags=${__LMLINE_ZSH_FLAGS[$index]:--}
  local n=${#__LMLINE_ZSH_CANDIDATES[@]} pos=$index truncated=0
  (( n > 0 )) || { n=1; pos=1; }
  [[ -n "$candidate" ]] || return 1
  # The flags field holds comma-separated markers, so a marker is present
  # only as a whole one: a token that merely carries the word does not
  # mark the candidate.
  [[ ",$flags," == *,truncated,* || "$candidate" == "# TRUNCATED: "* ]] && truncated=1
  if [[ "${__LMLINE_ZSH_LAST_MODE:-}" == rewrite && "$candidate" == "${__LMLINE_ZSH_LAST_ORIGINAL:-}" ]]; then
    BUFFER=$candidate
    CURSOR=${#BUFFER}
    if (( __LMLINE_ZSH_SHOW_CANDIDATE_COUNT == 1 && n > 1 )); then
      __lmline_zsh_hint "${LMLINE_PS0}${n} candidates$(__lmline_zsh_meta_status | sed 's/^/; /')"
    elif (( n > 1 )); then
      __lmline_zsh_hint "${LMLINE_PS0}${pos}/${n} (original)"
    else
      __lmline_zsh_clear_hint
    fi
    __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
    __lmline_zsh_record_suggestion "${__LMLINE_ZSH_LAST_MODE:-unknown}" "${__LMLINE_ZSH_LAST_ORIGINAL:-}" "$candidate"
    zle redisplay 2>/dev/null || true
    return 0
  fi
  case "$risk" in
    high)
      BUFFER="# REVIEW REQUIRED: $candidate"
      __lmline_zsh_hint "${LMLINE_PS0}${pos}/${n} high-risk; inserted as comment ($reason)"
      ;;
    medium)
      BUFFER=$candidate
      __lmline_zsh_hint "${LMLINE_PS0}${pos}/${n} medium-risk; review before Enter ($reason)"
      ;;
    *)
      BUFFER=$candidate
      if (( truncated == 1 )); then
        __lmline_zsh_hint "${LMLINE_PS0}${pos}/${n} candidate-truncated to ${LMLINE_MAX_CANDIDATE_BYTES:-4096} bytes"
      elif (( __LMLINE_ZSH_SHOW_CANDIDATE_COUNT == 1 && n > 1 )); then
        __lmline_zsh_hint "${LMLINE_PS0}${n} candidates$(__lmline_zsh_meta_status | sed 's/^/; /')"
      elif (( n > 1 )); then
        # Cycling: show the position so next/prev never feel like a no-op.
        __lmline_zsh_hint "${LMLINE_PS0}${pos}/${n}"
      else
        __lmline_zsh_clear_hint
      fi
      ;;
  esac
  __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
  # The flags field holds comma-separated markers, so the copilot marker is
  # present only as a whole one.
  if [[ ",$flags," == *,copilot:* ]]; then
    local token=",$flags"
    token=${token#*,copilot:}
    token=${token%%,*}
    [[ -n "$token" && "$token" != - ]] && { node "$LMLINE_DIR/copilot-client.js" accept "$token" >/dev/null 2>&1 &! }
  fi
  CURSOR=${#BUFFER}
  __lmline_zsh_record_suggestion "${__LMLINE_ZSH_LAST_MODE:-unknown}" "${__LMLINE_ZSH_LAST_ORIGINAL:-}" "$candidate"
  zle redisplay 2>/dev/null || true
}

__lmline_zsh_bridge_candidates() {
  local label=$1 action=$2 mode=$3 line=$4 point=$5 bridge_status output
  # Public widget entrypoints reload settings before routing; this inner helper
  # uses that snapshot instead of hashing the same file again.
  bridge_status=0
  __lmline_zsh_run_bridge "$label" "$action" "$mode" "$line" "$point" || bridge_status=$?
  output=$__LMLINE_ZSH_BRIDGE_OUTPUT
  if (( bridge_status != 0 )); then
    if (( bridge_status == 3 )); then
      __lmline_zsh_hint "${output%%$'\n'*}"
    else
      __lmline_zsh_hint "$(__lmline_zsh_engine_hint "$output")"
    fi
    zle redisplay 2>/dev/null || true
    return 1
  fi
  __lmline_zsh_set_candidates "$output"
  if (( ${#__LMLINE_ZSH_CANDIDATES[@]} == 0 )); then
    __lmline_zsh_hint "${LMLINE_PS0}no ${mode} candidate"
    zle redisplay 2>/dev/null || true
    return 1
  fi
  __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=1
  __lmline_zsh_apply_index 1
}

lmline-zsh-generate-widget() {
  __lmline_zsh_reload_settings_if_changed
  local mode line point
  line=$BUFFER
  point=$CURSOR
  mode=$(__lmline_zsh_mode "$line")
  __LMLINE_ZSH_LAST_ORIGINAL=$line
  __LMLINE_ZSH_LAST_MODE=$mode
  __LMLINE_ZSH_INDEX=1
  if [[ "$LMLINE_ASYNC" == 1 ]]; then
    __lmline_zsh_generate_async "$line" "$mode" "$point"
    return 0
  fi
  __lmline_zsh_bridge_candidates "[$mode]" generate "$mode" "$line" "$point"
}

lmline-zsh-rewrite-widget() {
  local line=$BUFFER point=$CURSOR
  if [[ -z "${line//[[:space:]]/}" ]]; then
    __lmline_zsh_hint "${LMLINE_PS0}no command to rewrite"
    zle redisplay 2>/dev/null || true
    return 0
  fi
  __lmline_zsh_reload_settings_if_changed
  __LMLINE_ZSH_LAST_ORIGINAL=$line
  __LMLINE_ZSH_LAST_MODE=rewrite
  __LMLINE_ZSH_INDEX=1
  __lmline_zsh_bridge_candidates "[rewrite]" generate rewrite "$line" "$point"
}

lmline-zsh-next-widget() {
  (( ${#__LMLINE_ZSH_CANDIDATES[@]} )) || return 0
  __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
  __LMLINE_ZSH_INDEX=$(( (__LMLINE_ZSH_INDEX % ${#__LMLINE_ZSH_CANDIDATES[@]}) + 1 ))
  __lmline_zsh_apply_index "$__LMLINE_ZSH_INDEX"
}

lmline-zsh-prev-widget() {
  (( ${#__LMLINE_ZSH_CANDIDATES[@]} )) || return 0
  __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
  __LMLINE_ZSH_INDEX=$(( (__LMLINE_ZSH_INDEX + ${#__LMLINE_ZSH_CANDIDATES[@]} - 2) % ${#__LMLINE_ZSH_CANDIDATES[@]} + 1 ))
  __lmline_zsh_apply_index "$__LMLINE_ZSH_INDEX"
}

# Streaming display: run the bridge in the foreground so SSE chunks appear as
# they arrive instead of being buffered behind the spinner.
__lmline_zsh_stream_enabled() {
  case "${LMLINE_STREAM:-0}" in
    1|true|TRUE|on|ON|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

lmline-zsh-explain-widget() {
  print -ru2 -- ""
  if __lmline_zsh_stream_enabled; then
    __lmline_zsh_bridge explain "" "$BUFFER" "$CURSOR" >&2
    zle redisplay 2>/dev/null || true
    return 0
  fi
  __lmline_zsh_run_bridge "explaining" explain "" "$BUFFER" "$CURSOR"
  __lmline_zsh_clear_hint
  print -ru2 -- "$__LMLINE_ZSH_BRIDGE_OUTPUT"
  zle redisplay 2>/dev/null || true
}

lmline-zsh-clip-widget() {
  print -ru2 -- ""
  if __lmline_zsh_stream_enabled; then
    __lmline_zsh_bridge clip "" "" "$CURSOR" >&2
    zle redisplay 2>/dev/null || true
    return 0
  fi
  __lmline_zsh_run_bridge "reading clipboard" clip "" "" "$CURSOR"
  __lmline_zsh_clear_hint
  print -ru2 -- "$__LMLINE_ZSH_BRIDGE_OUTPUT"
  zle redisplay 2>/dev/null || true
}

lmline-zsh-fix-widget() {
  local line=$BUFFER point=$CURSOR
  if [[ -z "${line//[[:space:]]/}" ]]; then
    __lmline_zsh_hint "${LMLINE_PS0}no command to fix"
    zle redisplay 2>/dev/null || true
    return 0
  fi
  __lmline_zsh_reload_settings_if_changed
  __LMLINE_ZSH_LAST_ORIGINAL=$line
  __LMLINE_ZSH_LAST_MODE=fix
  __LMLINE_ZSH_INDEX=1
  __lmline_zsh_bridge_candidates "[fix]" fix fix "$line" "$point"
}

zle -N lmline-zsh-generate-widget
zle -N lmline-zsh-rewrite-widget
zle -N lmline-zsh-next-widget
zle -N lmline-zsh-prev-widget
zle -N lmline-zsh-explain-widget
zle -N lmline-zsh-clip-widget
zle -N lmline-zsh-fix-widget

# shellcheck disable=SC1091
source "$LMLINE_DIR/completions/_lmline"
compdef _lmline lmline 2>/dev/null || true

if [[ "${LMLINE_BIND_KEYS:-1}" == 1 ]]; then
  for pair in \
    "${LMLINE_KEY_GENERATE}:lmline-zsh-generate-widget" "${LMLINE_KEY_REWRITE}:lmline-zsh-rewrite-widget" \
    "${LMLINE_KEY_NEXT}:lmline-zsh-next-widget" "${LMLINE_KEY_PREV}:lmline-zsh-prev-widget" \
    "${LMLINE_KEY_EXPLAIN}:lmline-zsh-explain-widget" "${LMLINE_KEY_FIX}:lmline-zsh-fix-widget" \
    "${LMLINE_KEY_CLIP}:lmline-zsh-clip-widget"; do
    bindkey -M emacs "${pair%%:*}" "${pair#*:}"
    bindkey -M viins "${pair%%:*}" "${pair#*:}"
  done
fi

__lmline_zsh_sync_async_notify_hook
