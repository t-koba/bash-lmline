#!/usr/bin/env bash

# Minimal config loading helpers for lmline. This file is meant to be sourced.

# Body-free residual-transport guard for hash boundaries. Fails closed when
# modern BASH_FUNC_*%% or exact legacy "() {" records remain in the environment
# inherited by the next hash child, including malformed names and protected
# same-name collisions. Reads values only into non-exported scratch, never
# evaluates or emits them. TEXT=()example remains ordinary data. Callers that
# already unexported live functions call only this cheap check; direct
# unsanitized sites call __lmline_prepare_hash_environment instead.
__lmline_check_no_function_transport() (
  [[ -o posix ]] || POSIXLY_CORRECT=1 || exit 1
  set +x
  unset -f command || exit 1
  command builtin local entry name_part value fd producer found
  command builtin export -n entry name_part value fd producer found || exit 1
  found=0
  command builtin exec {fd}< <(command /usr/bin/env -0) || exit 1
  producer=$!
  while IFS= command builtin read -r -d '' entry <&"$fd"; do
    case "$entry" in
      BASH_FUNC_*%%=*) found=1 ;;
      *=*)
        name_part=${entry%%=*}
        value=${entry#*=}
        case "$value" in '() {'*) found=1 ;; esac
        ;;
    esac
  done
  command builtin exec {fd}<&- || exit 1
  command builtin wait "$producer" || exit 1
  (( found == 0 ))
)

# Direct unsanitized hash sites call this only inside a private subshell.
# Unexport live functions without changing caller state or command resolution,
# then reject residual modern/legacy transport (including malformed names).
# Protected Bash never imports inherited bodies; even a live same-name function
# cannot erase its raw record. Ordinary Bash can also retain malformed or
# legacy records. Common hash consumers keep their one-time caller scrub and
# call only __lmline_check_no_function_transport via __lmline_hash_stdin.
__lmline_prepare_hash_environment() {
  local name functions_remaining boundary_dir
  # Startup and standalone config/sandbox hashes run before policy is loaded.
  # Load names-only collectors privately too; context-only callers must not
  # gain policy functions as a side effect of computing an identity.
  if ! (
    [[ -o posix ]] || POSIXLY_CORRECT=1 || exit 1
    unset -f command || exit 1
    command builtin declare -F __lmline_collect_exported_functions
  ) >/dev/null 2>&1; then
    boundary_dir=${BASH_SOURCE[0]%/*}
    [[ $boundary_dir != "${BASH_SOURCE[0]}" ]] || boundary_dir=.
    # shellcheck source=lmline/validation-boundary.bash
    source "$boundary_dir/validation-boundary.bash" || return 1
  fi
  if [[ -o privileged ]]; then
    functions_remaining=$(__lmline_collect_shell_functions 2>/dev/null) || return 1
  else
    functions_remaining=$(__lmline_collect_exported_functions 2>/dev/null) || return 1
  fi
  __lmline_unexport_function() { \export -nf -- "$@"; }
  __lmline_unexport_functions() {
    while [[ -n $functions_remaining ]]; do
      name=${functions_remaining%%$'\n'*}
      if [[ $functions_remaining == *$'\n'* ]]; then
        functions_remaining=${functions_remaining#*$'\n'}
      else
        functions_remaining=
      fi
      [[ -n $name ]] || continue
      __lmline_unexport_function "$name" 2>/dev/null || return 1
    done
  }
  if [[ -o posix ]]; then
    __lmline_unexport_functions || return 1
  else
    POSIXLY_CORRECT=1 __lmline_unexport_functions || return 1
  fi
  __lmline_check_no_function_transport || return 1
}

__lmline_settings_cksum() (
  __lmline_prepare_hash_environment || return 1
  cksum
)

__lmline_quote_single() {
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

# An output variable avoids a command substitution in the config loader; callers
# without one keep the original stdout form.
__lmline_parse_export_value() {
  local raw=$1 output_var=${2-} parsed
  case "$raw" in
    \'*\')
      parsed=${raw#\'}
      parsed=${parsed%\'}
      parsed=${parsed//\'\\\'\'/\'}
      ;;
    \"*\")
      return 1
      ;;
    *[\`\$\<\>\|\&\;\(\)\{\}[:space:]]*)
      return 1
      ;;
    *)
      parsed=$raw
      ;;
  esac
  if [[ -n "$output_var" ]]; then
    printf -v "$output_var" '%s' "$parsed"
  else
    printf '%s\n' "$parsed"
  fi
}

__lmline_load_export_file() {
  local file=$1 line key raw value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == export\ LMLINE_* ]] || continue
    line=${line#export }
    key=${line%%=*}
    raw=${line#*=}
    [[ "$key" =~ ^LMLINE_[A-Z0-9_]+$ && "$line" == *=* ]] || continue
    __lmline_parse_export_value "$raw" value || continue
    printf -v "$key" '%s' "$value"
    export "$key"
    __LMLINE_LOAD_KEYS+="$key"$'\n'
  done <"$file"
}

# Reload bookkeeping: which settings the loaded files define, so a later
# reload can drop values the files no longer contain (config unset, profile
# switches, file removal) instead of leaving them stale in long-lived
# shells. Key lists are newline-delimited strings (safe under set -u on
# bash 4.2); per-key values live in double-underscore variables that config
# files cannot define, so project files can neither observe nor corrupt them.
: "${__LMLINE_ENV_BASELINE_SET:=0}"
: "${__LMLINE_ENV_BASELINE_KEYS:=}"
: "${__LMLINE_FILE_KEYS:=}"
: "${__LMLINE_LOAD_KEYS:=}"

__lmline_key_in_list() {
  [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

# Forget values a previous bridge load provided (used by the zsh bridge,
# which runs this loader in a fresh shell per load inheriting the merged
# zsh environment). Keys listed in __LMLINE_ZSH_PREV_KEYS are dropped before
# the environment baseline is captured so inherited stale values are not
# mistaken for intentional user environment; files defining them re-set them.
# Must run before __lmline_capture_env_baseline.
__lmline_forget_bridge_keys() {
  local k
  for k in ${__LMLINE_ZSH_PREV_KEYS-}; do
    [[ "$k" =~ ^LMLINE_[A-Z0-9_]+$ ]] || continue
    # The bridge locates its files through LMLINE_CONFIG_DIR, so that
    # locator survives forgetting; files defining it still override it.
    [[ "$k" == LMLINE_CONFIG_DIR ]] && continue
    unset "$k"
  done
}

# Snapshot user-owned LMLINE_* values once per process, before file values
# are applied, so reloads can restore them when files stop defining a key.
__lmline_capture_env_baseline() {
  if (( __LMLINE_ENV_BASELINE_SET )); then
    return 0
  fi
  __LMLINE_ENV_BASELINE_SET=1
  local k
  local -a baseline_keys=()
  if [[ ${IFS-} == $' \t\n' ]]; then
    baseline_keys=( "${!LMLINE_@}" )
  else
    baseline_keys=( $(compgen -v LMLINE_ 2>/dev/null) )
  fi
  for k in "${baseline_keys[@]}"; do
    [[ "$k" =~ ^LMLINE_[A-Z0-9_]+$ ]] || continue
    __LMLINE_ENV_BASELINE_KEYS+="$k"$'\n'
    printf -v "__LMLINE_ENV_BASELINE_$k" '%s' "${!k}"
  done
}

# Drop values the current files no longer define. A previously file-owned key
# missing now is restored to its pre-file environment value (or unset) --
# but only while it still holds the value the files set, so intentional user
# changes made meanwhile are never cleared.
__lmline_reconcile_config_load() {
  local old_keys=$__LMLINE_FILE_KEYS new_keys= k cur stamp ref base
  local IFS=$'\n'
  if [[ -n "$__LMLINE_LOAD_KEYS" ]]; then
    local -A seen_keys=()
    # Loaders append only validated LMLINE_* names, so split on newlines here.
    # shellcheck disable=SC2086
    for k in $__LMLINE_LOAD_KEYS; do
      [[ -n "$k" ]] || continue
      if [[ -n "${seen_keys[$k]-}" ]]; then
        continue
      fi
      seen_keys[$k]=1
      new_keys+="$k"$'\n'
    done
    new_keys=${new_keys%$'\n'}
  fi
  for k in $old_keys; do
    [[ -n "$k" ]] || continue
    if __lmline_key_in_list "$new_keys" "$k"; then
      continue
    fi
    ref=__LMLINE_FILESTAMP_$k
    cur=${!k-}
    stamp=${!ref-}
    if [[ "$cur" == "$stamp" ]]; then
      if __lmline_key_in_list "$__LMLINE_ENV_BASELINE_KEYS" "$k"; then
        base=__LMLINE_ENV_BASELINE_$k
        printf -v "$k" '%s' "${!base}"
        export "$k"
      else
        unset "$k"
      fi
    fi
    unset "__LMLINE_FILESTAMP_$k"
  done
  __LMLINE_FILE_KEYS=$new_keys
  for k in $new_keys; do
    [[ -n "$k" ]] || continue
    printf -v "__LMLINE_FILESTAMP_$k" '%s' "${!k-}"
  done
}

# Portable mutual exclusion for config-dir writes. mkdir is atomic on POSIX
# filesystems and macOS has no flock(1), so a lock directory is used instead.
# Stale locks require manual removal with all writers stopped: checking a PID
# then deleting can erase a successor. LMLINE_NO_LOCK=1 disables locking entirely
# (for filesystems where mkdir atomicity is unreliable, e.g. some NFS mounts).
__lmline_lock_acquire() {
  local lockdir=$1 timeout=${2:-5} tries i=0
  [[ "${LMLINE_NO_LOCK:-0}" == 1 ]] && return 0
  tries=$(( timeout * 10 ))
  mkdir -p "${lockdir%/*}" 2>/dev/null || true
  while ! mkdir "$lockdir" 2>/dev/null; do
    if (( ++i >= tries )); then
      printf 'lmline: config is locked by another lmline process (remove %s only after stopping all writers if stale)\n' "$lockdir" >&2
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$lockdir/pid"
  return 0
}

# Releases only a lock owned by this process. A stale holder whose lock was
# stolen must not delete the thief's replacement directory.
__lmline_lock_release() {
  local lockdir=${1-} cur
  [[ "${LMLINE_NO_LOCK:-0}" == 1 ]] && return 0
  [[ -n "$lockdir" ]] || return 0
  [[ -d "$lockdir" ]] || return 0
  cur=$(cat "$lockdir/pid" 2>/dev/null) || cur=
  if [[ "$cur" != "$$" ]]; then
    printf 'lmline: lock %s is not owned by this process (holder %s); leaving it intact\n' "$lockdir" "${cur:-unknown}" >&2
    return 0
  fi
  rm -rf "$lockdir"
}

__lmline_init_dirs() {
  local dir=$1
  : "${LMLINE_DEFAULTS_DIR:=$dir/defaults}"
  : "${LMLINE_USER_RULES_DIR:=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}}"
}

# Loads the full config hierarchy in precedence order: persistent settings,
# then project config from the Git root, then project config from $PWD.
# All entry points (CLI, engine, bash/zsh init) share this single loader.
# Project files are only read when the user enabled LMLINE_PROJECT_CONFIG in
# their own settings or environment (off by default). Reconcile persistent
# settings before checking consent, so removing the opt-in also drops stale
# project-owned values; the gate runs before project files so they cannot
# enable themselves.
__lmline_load_all_config() {
  local config_dir=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline} root
  __lmline_capture_env_baseline
  __LMLINE_LOAD_KEYS=
  __lmline_load_export_file "$config_dir/settings.bash"
  __lmline_reconcile_config_load
  if [[ "${LMLINE_PROJECT_CONFIG:-0}" == 1 ]]; then
    if command -v git >/dev/null 2>&1 && root=$(git rev-parse --show-toplevel 2>/dev/null); then
      if [[ -f "$root/.lmline.bash" ]]; then
        __lmline_load_export_file "$root/.lmline.bash"
      fi
    fi
    if [[ -f "$PWD/.lmline.bash" ]]; then
      __lmline_load_export_file "$PWD/.lmline.bash"
    fi
    __lmline_reconcile_config_load
  fi
  return 0
}

# Re-reads settings.bash when its content changed on disk since the last
# load, so "lmline config set" takes effect without restarting the shell.
# Content identity (not second-precision mtimes) catches atomic replacements
# made within the same second. Widgets call this before routing; config_dir
# must come from the caller because LMLINE_CONFIG_DIR is not exported by the
# shell integrations.
__lmline_reload_settings_if_changed() {
  local config_dir=${1:-${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}} file sum
  file=$config_dir/settings.bash
  if [[ -f "$file" ]]; then
    sum=$(__lmline_settings_cksum <"$file" 2>/dev/null) || sum=
    [[ -n "$sum" ]] || return 0
  else
    # A deleted file is also a change: reload so file-owned values are dropped.
    sum="no-settings-file"
  fi
  [[ "$sum" == "${__LMLINE_SETTINGS_CKSUM:-}" ]] && return 0
  __LMLINE_SETTINGS_CKSUM=$sum
  __lmline_load_all_config
  return 0
}

__lmline_decimal_gt() {
  local left=$1 right=$2
  (( ${#left} > ${#right} )) && return 0
  (( ${#left} < ${#right} )) && return 1
  # Inputs are canonical ASCII decimals; compare equal-length strings in C
  # locale so the result cannot overflow Bash arithmetic.
  # shellcheck disable=SC2071
  if [[ "$left" > "$right" ]]; then
    return 0
  fi
  return 1
}

__lmline_clamp_int() {
  local name=$1 default=$2 max=${3:-0} allow_zero=${4:-0} value pattern='^[1-9][0-9]*$' LC_ALL=C
  [[ "$allow_zero" == 1 ]] && pattern='^[0-9]+$'
  value=${!name-}
  if [[ ! "$value" =~ $pattern ]]; then
    value=$default
  else
    if [[ "$allow_zero" == 1 ]]; then
      # Bash reads leading zeros as octal, so canonicalize accepted decimals
      # before any arithmetic: 010 becomes 10 and 08 becomes 8.
      value=${value#"${value%%[!0]*}"}
      [[ -z "$value" ]] && value=0
    fi
    # Compare decimals as strings so arbitrarily long inputs cannot wrap
    # Bash arithmetic and miss the bound.
    local max_norm=$max
    max_norm=${max_norm#"${max_norm%%[!0]*}"}
    [[ -z "$max_norm" ]] && max_norm=0
    if [[ "$max_norm" != 0 ]]; then
      __lmline_decimal_gt "$value" "$max_norm" && value=$max_norm
    elif __lmline_decimal_gt "$value" 9223372036854775807; then
      # Unbounded settings must still fit Bash arithmetic; anything larger
      # falls back to the existing default instead of erroring or wrapping.
      value=$default
    fi
  fi
  printf -v "$name" '%s' "$value"
}

__lmline_resolve_data_file() {
  local label=$1 explicit=$2 user_file=$3 default_file=$4
  if [[ -n "$explicit" ]]; then
    [[ -r "$explicit" ]] || { printf 'lmline: %s file is not readable: %s\n' "$label" "$explicit" >&2; return 1; }
    printf '%s\n' "$explicit"; return 0
  fi
  for path in "$user_file" "$default_file"; do
    [[ -e "$path" ]] || continue
    [[ -r "$path" ]] || { printf 'lmline: %s file is not readable: %s\n' "$label" "$path" >&2; return 1; }
    printf '%s\n' "$path"; return 0
  done
  printf 'lmline: %s default file is missing or unreadable: %s\n' "$label" "$default_file" >&2
  return 1
}

__lmline_clipboard_provider_file() {
  __lmline_resolve_data_file clipboard_providers \
    "${LMLINE_CLIPBOARD_PROVIDERS_FILE:-}" \
    "$LMLINE_USER_RULES_DIR/clipboard_providers.tsv" \
    "$LMLINE_DEFAULTS_DIR/clipboard_providers.tsv"
}

__lmline_clipboard_provider_names() {
  local file
  file=$(__lmline_clipboard_provider_file) || return 1
  # Match Bash's IFS-tab splitting: ignore empty columns but retain spaces.
  awk 'BEGIN { FS = sprintf("%c", 9) }
    $0 == "" || /^#/ { next }
    {
      i = 1
      while (i <= NF && $i == "") i++
      if (i > NF) next
      name = $i
      i++
      while (i <= NF && $i == "") i++
      if (i <= NF) print name
    }' <"$file"
}

__lmline_read_list_file() {
  local file=${1-} line
  [[ -n "$file" && -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done <"$file"
}
