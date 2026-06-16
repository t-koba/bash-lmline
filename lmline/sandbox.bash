#!/usr/bin/env bash

# Execution backends and microsandbox CLI integration.

: "${LMLINE_EXEC_BACKEND:=auto}"
: "${LMLINE_MICROSANDBOX_COMMAND:=msb}"
: "${LMLINE_MICROSANDBOX_IMAGE:=debian}"
: "${LMLINE_MICROSANDBOX_MEMORY:=512M}"
: "${LMLINE_MICROSANDBOX_CPUS:=1}"
: "${LMLINE_MICROSANDBOX_NAME:=}"
: "${LMLINE_MICROSANDBOX_WORKDIR:=/workspace}"
: "${LMLINE_MICROSANDBOX_WORKSPACE_MODE:=readonly}"
: "${LMLINE_MICROSANDBOX_SETUP_TIMEOUT:=30}"
: "${LMLINE_MICROSANDBOX_REQUIRED_COMMANDS:=}"

__lmline_exec_backend_setting() {
  case "${LMLINE_EXEC_BACKEND:-auto}" in
    auto|local|microsandbox|off) printf '%s\n' "${LMLINE_EXEC_BACKEND:-auto}" ;;
    *) printf 'auto\n' ;;
  esac
}

__lmline_microsandbox_command_path() {
  local command_name=${LMLINE_MICROSANDBOX_COMMAND:-msb}
  [[ -n "$command_name" ]] || return 1
  command -v "$command_name" 2>/dev/null
}

__lmline_microsandbox_available() {
  __lmline_microsandbox_command_path >/dev/null 2>&1
}

__lmline_select_exec_backend() {
  local setting
  setting=$(__lmline_exec_backend_setting)
  case "$setting" in
    off)
      printf 'off\n'
      return 1
      ;;
    local)
      printf 'local\n'
      ;;
    microsandbox)
      __lmline_microsandbox_available || {
        printf 'microsandbox\n'
        return 1
      }
      printf 'microsandbox\n'
      ;;
    auto)
      if __lmline_microsandbox_available; then
        printf 'microsandbox\n'
      else
        printf 'local\n'
      fi
      ;;
  esac
}

__lmline_microsandbox_with_host_timeout() {
  local timeout_s=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_s" "$@"
  else
    "$@"
  fi
}

__lmline_microsandbox_cli_capture() {
  local command_line=$1 timeout_s=$2 stdout_file=$3 stderr_file=$4 status=0
  local msb image=${LMLINE_MICROSANDBOX_IMAGE:-debian} name=${LMLINE_MICROSANDBOX_NAME:-}
  local workdir=${LMLINE_MICROSANDBOX_WORKDIR:-/workspace}
  msb=$(__lmline_microsandbox_command_path) || return 1
  if [[ -n "$name" ]]; then
    __lmline_microsandbox_with_host_timeout "$timeout_s" \
      "$msb" --error exec "$name" --timeout "${timeout_s}s" -w "$workdir" -- sh -c "$command_line" \
      >"$stdout_file" 2>"$stderr_file" || status=$?
  else
    __lmline_microsandbox_with_host_timeout "$timeout_s" \
      "$msb" --error run "$image" -- sh -c "$command_line" \
      >"$stdout_file" 2>"$stderr_file" || status=$?
  fi
  __LMLINE_EXEC_STATUS=$status
  __LMLINE_EXEC_BACKEND_USED=microsandbox
  return 0
}

__lmline_microsandbox_check() {
  local msb version status=0
  msb=$(__lmline_microsandbox_command_path) || {
    printf 'available=0\n'
    printf 'command=%s\n' "${LMLINE_MICROSANDBOX_COMMAND:-msb}"
    printf 'reason=command_not_found\n'
    return 1
  }
  version=$("$msb" --version 2>/dev/null) || status=$?
  printf 'available=1\n'
  printf 'command=%s\n' "${LMLINE_MICROSANDBOX_COMMAND:-msb}"
  printf 'path=%s\n' "$msb"
  if (( status == 0 )) && [[ -n "$version" ]]; then
    printf 'version=%s\n' "$version"
  else
    printf 'version=unknown\n'
  fi
}

__lmline_sandbox_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print substr($1, 1, 16)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print substr($1, 1, 16)}'
  else
    cksum | awk '{print $1}'
  fi
}

__lmline_default_sandbox_name() {
  local root=${1:-$PWD} hash
  hash=$(printf '%s' "$root" | __lmline_sandbox_hash)
  printf 'lmline-%s\n' "$hash"
}

__lmline_project_root_for_sandbox() {
  local root
  if command -v git >/dev/null 2>&1 && root=$(git rev-parse --show-toplevel 2>/dev/null); then
    (cd -P -- "$root" 2>/dev/null && pwd -P)
  else
    pwd -P
  fi
}

__lmline_sandbox_required_commands() {
  local c file
  if declare -F __lmline_local_commands_file >/dev/null 2>&1; then
    file=$(__lmline_local_commands_file 2>/dev/null || true)
    [[ -n "$file" ]] && __lmline_read_list_file "$file"
  fi
  if declare -F __lmline_collect_suggested_commands >/dev/null 2>&1; then
    __lmline_collect_suggested_commands 2>/dev/null || true
  fi
  for c in ${LMLINE_MICROSANDBOX_REQUIRED_COMMANDS:-}; do
    printf '%s\n' "$c"
  done
}

__lmline_env_manifest_for_sandbox() {
  local root=$1 name=$2
  jq -n \
    --arg root "$root" \
    --arg name "$name" \
    --arg shell "${SHELL:-}" \
    --arg path "${PATH:-}" \
    --arg lang "${LANG:-}" \
    --arg lc_all "${LC_ALL:-}" \
    --arg lc_messages "${LC_MESSAGES:-}" \
    --arg ostype "${OSTYPE:-}" \
    --arg uname "$(uname -a 2>/dev/null || true)" \
    '{
      sandboxName: $name,
      hostProjectRoot: $root,
      hostShell: $shell,
      hostPath: $path,
      lang: $lang,
      lcAll: $lc_all,
      lcMessages: $lc_messages,
      ostype: $ostype,
      uname: $uname
    }'
}

__lmline_microsandbox_mount_arg() {
  local workspace_mode=$1 root=$2 workdir=$3 option
  case "$workspace_mode" in
    readonly) option=ro ;;
    writable) option=rw ;;
    none) return 1 ;;
    *) return 2 ;;
  esac
  printf '%s:%s:%s\n' "$root" "$workdir" "$option"
}

__lmline_quote_words_for_setup_check() {
  local word
  for word in "$@"; do
    printf ' %q' "$word"
  done
}

__lmline_microsandbox_setup() {
  local name=$1 image=$2 workspace_mode=$3 root=$4 workdir=$5 timeout_s=${6:-${LMLINE_MICROSANDBOX_SETUP_TIMEOUT:-30}}
  local memory=${LMLINE_MICROSANDBOX_MEMORY:-512M} cpus=${LMLINE_MICROSANDBOX_CPUS:-1}
  local msb mount_arg created=0 required check_script check_text manifest_file inspect_status=0
  local status=0
  [[ "$cpus" =~ ^[1-9][0-9]*$ ]] || cpus=1
  [[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || timeout_s=30
  command -v jq >/dev/null 2>&1 || {
    printf 'lmline: jq is required for sandbox setup\n' >&2
    return 1
  }
  msb=$(__lmline_microsandbox_command_path) || {
    printf 'lmline: microsandbox CLI not found: %s\n' "${LMLINE_MICROSANDBOX_COMMAND:-msb}" >&2
    printf 'lmline: install microsandbox and make msb available on PATH, or set LMLINE_MICROSANDBOX_COMMAND\n' >&2
    return 1
  }
  "$msb" --error inspect "$name" >/dev/null 2>&1 || inspect_status=$?
  if (( inspect_status == 0 )); then
    "$msb" --error start -q "$name" >/dev/null 2>&1 || true
  else
    local -a create_cmd
    create_cmd=("$msb" --error create "$image" --name "$name" -c "$cpus" -m "$memory" -w "$workdir")
    case "$workspace_mode" in
      readonly|writable)
        mount_arg=$(__lmline_microsandbox_mount_arg "$workspace_mode" "$root" "$workdir") || return 1
        create_cmd+=(--mount-dir "$mount_arg")
        ;;
      none) ;;
      *)
        printf 'lmline: invalid workspace mode: %s\n' "$workspace_mode" >&2
        return 2
        ;;
    esac
    __lmline_microsandbox_with_host_timeout "$timeout_s" "${create_cmd[@]}" >/dev/null || return 1
    created=1
  fi

  manifest_file=$(mktemp "${TMPDIR:-/tmp}/lmline-sandbox-env.XXXXXX") || return 1
  __lmline_env_manifest_for_sandbox "$root" "$name" >"$manifest_file" || {
    rm -f "$manifest_file"
    return 1
  }
  "$msb" --error copy "$manifest_file" "$name:/etc/lmline-env.json" >/dev/null 2>&1 || true
  rm -f "$manifest_file"

  required=$(__lmline_sandbox_required_commands | awk 'NF && !seen[$0]++')
  if [[ -n "$required" ]]; then
    check_script='for c in'
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      check_script+=$(__lmline_quote_words_for_setup_check "$c")
    done <<<"$required"
    check_script+='; do if command -v "$c" >/dev/null 2>&1; then printf "ok %s\n" "$c"; else printf "missing %s\n" "$c"; fi; done'
    check_text=$(__lmline_microsandbox_with_host_timeout "$timeout_s" \
      "$msb" --error exec "$name" --timeout "${timeout_s}s" -- sh -c "$check_script") || status=$?
    if (( status != 0 )); then
      printf 'lmline: sandbox command check failed\n' >&2
      return 1
    fi
  fi

  printf 'sandbox_name=%s\n' "$name"
  printf 'created=%s\n' "$created"
  printf 'image=%s\n' "$image"
  printf 'project_root=%s\n' "$root"
  printf 'workdir=%s\n' "$workdir"
  printf 'workspace_mode=%s\n' "$workspace_mode"
  if [[ -n "${check_text:-}" ]]; then
    printf 'command_check:\n'
    printf '%s\n' "$check_text" | sed 's/^/  /'
  fi
}
