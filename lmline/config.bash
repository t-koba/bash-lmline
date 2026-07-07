#!/usr/bin/env bash

# Minimal config loading helpers for lmline. This file is meant to be sourced.

__lmline_quote_single() {
  local value=$1
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

__lmline_parse_export_value() {
  local raw=$1 value
  case "$raw" in
    \'*\')
      value=${raw#\'}
      value=${value%\'}
      value=${value//\'\\\'\'/\'}
      printf '%s\n' "$value"
      ;;
    \"*\")
      return 1
      ;;
    *[\`\$\<\>\|\&\;\(\)\{\}[:space:]]*)
      return 1
      ;;
    *)
      printf '%s\n' "$raw"
      ;;
  esac
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
    value=$(__lmline_parse_export_value "$raw") || continue
    printf -v "$key" '%s' "$value"
    export "$key"
  done <"$file"
}

# Portable mutual exclusion for config-dir writes. mkdir is atomic on POSIX
# filesystems and macOS has no flock(1), so a lock directory is used instead.
# Holder liveness is tracked via a pid file inside the lock directory; locks
# whose holder is gone are stolen. LMLINE_NO_LOCK=1 disables locking entirely
# (for filesystems where mkdir atomicity is unreliable, e.g. some NFS mounts).
__lmline_lock_acquire() {
  local lockdir=$1 timeout=${2:-5} tries i=0 pid
  [[ "${LMLINE_NO_LOCK:-0}" == 1 ]] && return 0
  tries=$(( timeout * 10 ))
  mkdir -p "${lockdir%/*}" 2>/dev/null || true
  while ! mkdir "$lockdir" 2>/dev/null; do
    pid=$(cat "$lockdir/pid" 2>/dev/null) || pid=
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lockdir"
      continue
    fi
    if [[ -z "$pid" && -n "$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      # The holder died between mkdir and writing its pid file.
      rm -rf "$lockdir"
      continue
    fi
    if (( ++i >= tries )); then
      printf 'lmline: config is locked by another lmline process (remove %s if stale)\n' "$lockdir" >&2
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$lockdir/pid"
  return 0
}

__lmline_lock_release() {
  [[ "${LMLINE_NO_LOCK:-0}" == 1 ]] && return 0
  rm -rf "$1"
}

__lmline_init_dirs() {
  local dir=$1
  : "${LMLINE_DEFAULTS_DIR:=$dir/defaults}"
  : "${LMLINE_USER_RULES_DIR:=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}}"
}

# Loads the full config hierarchy in precedence order: persistent settings,
# then project config from the Git root, then project config from $PWD.
# All entry points (CLI, engine, bash/zsh init) share this single loader.
__lmline_load_all_config() {
  local config_dir=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline} root
  __lmline_load_export_file "$config_dir/settings.bash"
  if command -v git >/dev/null 2>&1 && root=$(git rev-parse --show-toplevel 2>/dev/null); then
    if [[ -f "$root/.lmline.bash" ]]; then
      __lmline_load_export_file "$root/.lmline.bash"
    fi
  fi
  if [[ -f "$PWD/.lmline.bash" ]]; then
    __lmline_load_export_file "$PWD/.lmline.bash"
  fi
  return 0
}

__lmline_clamp_int() {
  local name=$1 default=$2 max=${3:-0} allow_zero=${4:-0} value pattern='^[1-9][0-9]*$'
  [[ "$allow_zero" == 1 ]] && pattern='^[0-9]+$'
  value=${!name-}
  if [[ ! "$value" =~ $pattern ]]; then
    value=$default
  elif (( max > 0 && value > max )); then
    value=$max
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
