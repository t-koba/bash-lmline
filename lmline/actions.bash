#!/usr/bin/env bash

# User-facing lmline actions that call the engine. This file is meant to be sourced
# after config.bash, policy.bash, and context.bash.

__LMLINE_ACTIONS_DIR=${BASH_SOURCE[0]%/*}
[[ $__LMLINE_ACTIONS_DIR == "${BASH_SOURCE[0]}" ]] && __LMLINE_ACTIONS_DIR=.
__LMLINE_ACTIONS_DIR=$(cd -- "$__LMLINE_ACTIONS_DIR" && pwd -P)
if ! declare -F __lmline_engine_error_message >/dev/null 2>&1; then
  # shellcheck source=lmline/http.bash
  source "$__LMLINE_ACTIONS_DIR/http.bash"
fi

# The engine emits one preformatted "lmline-status:" line; extract it verbatim.
__lmline_action_meta_status() {
  local output=$1
  printf '%s\n' "$output" | awk '/^lmline-status: / { sub(/^lmline-status: /, ""); last=$0 } END { if (last != "") print last }'
}

__lmline_action_strip_runtime_lines() {
  sed '/^lmline-progress: /d; /^lmline-meta: /d; /^lmline-status: /d'
}

# Streaming display applies to explain/clip when LMLINE_STREAM is enabled.
# The engine streams through tool rounds too; tool progress is reported on
# stderr and the final answer streams to stdout.
__lmline_stream_display_enabled() {
  case "${LMLINE_STREAM:-0}" in
    1|true|TRUE|on|ON|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Runs the engine in the foreground with stdout attached to the caller so SSE
# chunks appear as they arrive. Returns the engine status; status/meta lines
# are read from the captured stderr file.
__lmline_action_stream_engine() {
  local prefix=$1 stderr_file=$2 engine_status error meta_status
  shift 2
  "$@" 2>"$stderr_file"
  engine_status=$?
  if (( engine_status != 0 )); then
    error=$(__lmline_action_strip_runtime_lines <"$stderr_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c 1-300)
    __lmline_engine_error_message "$prefix" "${error:-engine exited with status $engine_status}"
    return "$engine_status"
  fi
  meta_status=$(__lmline_action_meta_status "$(cat "$stderr_file" 2>/dev/null)")
  [[ -n "$meta_status" ]] && printf '%s%s\n' "$prefix" "$meta_status"
  return 0
}

__lmline_clipboard_provider_file() {
  __lmline_resolve_data_file clipboard_providers \
    "${LMLINE_CLIPBOARD_PROVIDERS_FILE:-}" \
    "$LMLINE_USER_RULES_DIR/clipboard_providers.tsv" \
    "$LMLINE_DEFAULTS_DIR/clipboard_providers.tsv"
}

__lmline_clipboard_provider_line() {
  local wanted=${LMLINE_CLIPBOARD_PROVIDER:-auto} file line
  local -a fields
  file=$(__lmline_clipboard_provider_file) || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r -a fields <<<"$line"
    ((${#fields[@]} >= 2)) || continue
    if [[ "$wanted" == auto ]]; then
      if command -v "${fields[1]}" >/dev/null 2>&1; then
        printf '%s\n' "$line"
        return 0
      fi
    elif [[ "${fields[0]}" == "$wanted" ]]; then
      command -v "${fields[1]}" >/dev/null 2>&1 || {
        printf 'lmline: clipboard provider command not found: %s\n' "${fields[1]}" >&2
        return 1
      }
      printf '%s\n' "$line"
      return 0
    fi
  done <"$file"
  if [[ "$wanted" == auto ]]; then
    printf 'lmline: no clipboard provider found; install pbpaste, wl-paste, xclip, xsel, powershell.exe, or tmux, or set LMLINE_CLIPBOARD_PROVIDER\n' >&2
  else
    printf 'lmline: clipboard provider not configured: %s\n' "$wanted" >&2
  fi
  return 1
}

__lmline_clipboard_provider_names() {
  local file line
  local -a fields
  file=$(__lmline_clipboard_provider_file) || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r -a fields <<<"$line"
    ((${#fields[@]} >= 2)) || continue
    printf '%s\n' "${fields[0]}"
  done <"$file"
}

__lmline_clipboard_provider_list() {
  local file line status
  local -a fields
  file=$(__lmline_clipboard_provider_file) || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r -a fields <<<"$line"
    ((${#fields[@]} >= 2)) || continue
    if command -v "${fields[1]}" >/dev/null 2>&1; then
      status=available
    else
      status=missing
    fi
    printf '%s\t%s\t%s' "${fields[0]}" "$status" "${fields[1]}"
    if ((${#fields[@]} > 2)); then
      printf '\t%s' "${fields[@]:2}"
    fi
    printf '\n'
  done <"$file"
}

__lmline_clipboard_status() {
  local line
  if line=$(__lmline_clipboard_provider_line 2>/dev/null); then
    local -a fields
    IFS=$'\t' read -r -a fields <<<"$line"
    printf 'clipboard_provider=%s\nclipboard_command=%s' "${fields[0]}" "${fields[1]}"
    if ((${#fields[@]} > 2)); then
      printf '\nclipboard_args='
      printf '%s ' "${fields[@]:2}"
      printf '\n'
    else
      printf '\n'
    fi
  else
    printf 'clipboard_provider=missing\n'
    printf '  -> set LMLINE_CLIPBOARD_PROVIDER or install a supported clipboard command\n'
  fi
}

__lmline_clipboard_read() {
  local wanted=${LMLINE_CLIPBOARD_PROVIDER:-auto} file line output errors=""
  local -a fields args
  if [[ "$wanted" == auto ]]; then
    file=$(__lmline_clipboard_provider_file) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      IFS=$'\t' read -r -a fields <<<"$line"
      ((${#fields[@]} >= 2)) || continue
      command -v "${fields[1]}" >/dev/null 2>&1 || continue
      args=("${fields[@]:2}")
      if output=$("${fields[1]}" "${args[@]}" 2>&1); then
        __LMLINE_CLIPBOARD_PROVIDER_USED=${fields[0]}
        __LMLINE_CLIPBOARD_COMMAND_USED=${fields[1]}
        printf '%s' "$output"
        return 0
      fi
      errors+="${errors:+; }${fields[0]}: ${output%%$'\n'*}"
    done <"$file"
    printf 'lmline: no usable clipboard provider found%s\n' "${errors:+ ($errors)}" >&2
    return 1
  fi
  line=$(__lmline_clipboard_provider_line) || return 1
  IFS=$'\t' read -r -a fields <<<"$line"
  __LMLINE_CLIPBOARD_PROVIDER_USED=${fields[0]}
  __LMLINE_CLIPBOARD_COMMAND_USED=${fields[1]}
  args=("${fields[@]:2}")
  "${fields[1]}" "${args[@]}"
}

__lmline_redact_clip_text() {
  sed -E \
    -e 's/([A-Za-z_][A-Za-z0-9_]*(TOKEN|Token|token|SECRET|Secret|secret|PASSWORD|Password|password|PASS|Pass|pass|KEY|Key|key)[A-Za-z0-9_]*[=:][[:space:]]*)[^[:space:]]+/\1***REDACTED***/g' \
    -e 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1***REDACTED***/g' \
    -e 's/(sk-[A-Za-z0-9_-]{12})[A-Za-z0-9_-]+/\1***REDACTED***/g' \
    -e 's/(ghp_[A-Za-z0-9]{12})[A-Za-z0-9]+/\1***REDACTED***/g'
}

__lmline_prepare_clip_input() {
  local question=$1 clipboard=$2 provider=$3 max_input=${LMLINE_CLIP_MAX_INPUT_BYTES:-65536}
  local raw_bytes redacted input_bytes truncated=0
  [[ "$max_input" =~ ^[1-9][0-9]*$ ]] || max_input=65536
  raw_bytes=$(LC_ALL=C printf '%s' "$clipboard" | wc -c | tr -d ' ')
  redacted=$(printf '%s' "$clipboard" | __lmline_redact_clip_text)
  input_bytes=$(LC_ALL=C printf '%s' "$redacted" | wc -c | tr -d ' ')
  if (( input_bytes > max_input )); then
    redacted=$(printf '%s' "$redacted" | LC_ALL=C cut -c "1-$max_input")
    truncated=1
  fi
  cat <<EOF
Question:
${question:-Analyze the clipboard content. Explain the likely issue and suggest practical next steps.}

Clipboard provider: $provider
Clipboard original bytes: $raw_bytes
Clipboard redacted bytes: $input_bytes
Clipboard max bytes sent: $max_input
Clipboard truncated: $truncated

Pasted terminal or clipboard text:
$redacted
EOF
}

__lmline_print_clip() {
  local engine=$1 shell_name=$2 question=$3 prefix=$4
  local tmp clipboard clip_input engine_output engine_status error had_errexit=0 max_output output_bytes meta_status provider
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-clip.XXXXXX") || return 1
  __lmline_clipboard_read >"$tmp/clipboard" || {
    rm -rf "$tmp"
    return 1
  }
  clipboard=$(cat "$tmp/clipboard")
  provider=${__LMLINE_CLIPBOARD_PROVIDER_USED:-unknown}
  [[ -n "$clipboard" ]] || {
    rm -rf "$tmp"
    printf '%sclipboard is empty (provider=%s)\n' "$prefix" "$provider"
    return 1
  }
  clip_input=$(__lmline_prepare_clip_input "$question" "$clipboard" "$provider")
  printf '%s' "$clip_input" >"$tmp/line"
  __lmline_context_file "$tmp/context" "$question" || {
    rm -rf "$tmp"
    printf '%scontext error\n' "$prefix"
    return 1
  }
  printf '%sclipboard provider=%s\n' "$prefix" "$provider"
  printf '%smodel response:\n' "$prefix"
  if __lmline_stream_display_enabled; then
    [[ $- == *e* ]] && had_errexit=1
    set +e
    __lmline_action_stream_engine "$prefix" "$tmp/stderr" \
      "$engine" --mode clip --shell "$shell_name" --cwd "$PWD" --point "${#clip_input}" --line-file "$tmp/line" --context-file "$tmp/context" --n 1
    engine_status=$?
    (( had_errexit == 1 )) && set -e
    rm -rf "$tmp"
    return "$engine_status"
  fi
  [[ $- == *e* ]] && had_errexit=1
  set +e
  engine_output=$("$engine" --mode clip --shell "$shell_name" --cwd "$PWD" --point "${#clip_input}" --line-file "$tmp/line" --context-file "$tmp/context" --n 1 2>&1)
  engine_status=$?
  (( had_errexit == 1 )) && set -e
  rm -rf "$tmp"
  if (( engine_status != 0 )); then
    error=$(printf '%s' "${engine_output:-engine exited with status $engine_status}" | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c 1-300)
    __lmline_engine_error_message "$prefix" "$error"
    return "$engine_status"
  fi
  meta_status=$(__lmline_action_meta_status "$engine_output")
  engine_output=$(printf '%s\n' "$engine_output" | __lmline_action_strip_runtime_lines)
  [[ -n "$meta_status" ]] && printf '%s%s\n' "$prefix" "$meta_status"
  max_output=${LMLINE_CLIP_MAX_OUTPUT_BYTES:-65536}
  [[ "$max_output" =~ ^[1-9][0-9]*$ ]] || max_output=65536
  output_bytes=$(LC_ALL=C printf '%s' "$engine_output" | wc -c | tr -d ' ')
  if (( output_bytes > max_output )); then
    printf '%s\n' "$engine_output" | LC_ALL=C cut -c "1-$max_output"
    printf '\n%sclip-output-truncated original_bytes=%s max_bytes=%s\n' "$prefix" "$output_bytes" "$max_output"
    return 0
  fi
  printf '%s\n' "$engine_output"
}

__lmline_print_explanation() {
  local engine=$1 shell_name=$2 line=$3 point=$4 prefix=$5
  local tmp risk reason risk_match engine_output engine_status error had_errexit=0 max_output output_bytes meta_status
  [[ -n "${line//[[:space:]]/}" ]] || {
    printf '%sno command to explain\n' "$prefix"
    return 0
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-expl.XXXXXX") || return 1
  printf '%s' "$line" >"$tmp/line"
  __lmline_context_file "$tmp/context" "$line" || {
    rm -rf "$tmp"
    printf '%scontext error\n' "$prefix"
    return 1
  }
  risk_match=$(__lmline_risk_match "$line") || {
    rm -rf "$tmp"
    printf '%spolicy error\n' "$prefix"
    return 1
  }
  risk=${risk_match%%$'\t'*}
  reason=${risk_match#*$'\t'}
  [[ -n "$risk_match" ]] || { risk=low; reason="no matching risk rule"; }
  printf '%scommand: %s\n' "$prefix" "$line"
  printf '%srisk=%s reason=%s\n' "$prefix" "$risk" "$reason"
  printf '%scommand summary:\n' "$prefix"
  __lmline_collect_command_summaries "$line" || true
  printf '%smodel explanation:\n' "$prefix"
  if __lmline_stream_display_enabled; then
    [[ $- == *e* ]] && had_errexit=1
    set +e
    __lmline_action_stream_engine "$prefix" "$tmp/stderr" \
      "$engine" --mode explain --shell "$shell_name" --cwd "$PWD" --point "$point" --line-file "$tmp/line" --context-file "$tmp/context" --n 1
    engine_status=$?
    (( had_errexit == 1 )) && set -e
    rm -rf "$tmp"
    return "$engine_status"
  fi
  [[ $- == *e* ]] && had_errexit=1
  set +e
  if declare -F __lmline_run_explain_engine >/dev/null 2>&1; then
    engine_output=$(__lmline_run_explain_engine "$engine" "$shell_name" "$point" "$tmp/line" "$tmp/context")
  else
    engine_output=$("$engine" --mode explain --shell "$shell_name" --cwd "$PWD" --point "$point" --line-file "$tmp/line" --context-file "$tmp/context" --n 1 2>&1)
  fi
  engine_status=$?
  (( had_errexit == 1 )) && set -e
  rm -rf "$tmp"
  if (( engine_status != 0 )); then
    if [[ -n "$engine_output" ]]; then
      error=$(printf '%s' "$engine_output" | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c 1-300)
    else
      error="engine exited with status $engine_status"
    fi
    __lmline_engine_error_message "$prefix" "$error"
    return "$engine_status"
  fi
  meta_status=$(__lmline_action_meta_status "$engine_output")
  engine_output=$(printf '%s\n' "$engine_output" | __lmline_action_strip_runtime_lines)
  [[ -n "$meta_status" ]] && printf '%s%s\n' "$prefix" "$meta_status"
  max_output=${LMLINE_EXPLAIN_MAX_OUTPUT_BYTES:-65536}
  output_bytes=$(LC_ALL=C printf '%s' "$engine_output" | wc -c | tr -d ' ')
  if (( output_bytes > max_output )); then
    printf '%s\n' "$engine_output" | LC_ALL=C cut -c "1-$max_output"
    printf '\n%sexplanation-truncated original_bytes=%s max_bytes=%s\n' "$prefix" "$output_bytes" "$max_output"
    return 0
  fi
  printf '%s\n' "$engine_output"
}

__lmline_fix_run() {
  local line=$1 shell_name=$2 point=$3 engine=$4 n=$5 prefix=${6:-}
  local risk timeout=${LMLINE_FIX_TIMEOUT:-12} max_output=${LMLINE_FIX_MAX_OUTPUT:-12000}
  local tmp status engine_status

  risk=$(__lmline_risk_level "$line") || {
    printf '%spolicy error\n' "$prefix" >&2
    return 3
  }
  case "$risk" in
    high)
      printf '%sfix refused for high-risk command\n' "$prefix" >&2
      return 3
      ;;
    medium)
      if [[ "${LMLINE_FIX_ALLOW_MEDIUM:-0}" != 1 ]]; then
        printf '%sfix refused for medium-risk command; set LMLINE_FIX_ALLOW_MEDIUM=1\n' "$prefix" >&2
        return 3
      fi
      ;;
  esac

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-fix.XXXXXX") || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout" bash -lc "$line" >"$tmp/stdout" 2>"$tmp/stderr"
    status=$?
  else
    bash -lc "$line" >"$tmp/stdout" 2>"$tmp/stderr"
    status=$?
  fi
  __lmline_trim_file_bytes "$tmp/stdout" "$max_output"
  __lmline_trim_file_bytes "$tmp/stderr" "$max_output"
  if (( status == 0 )); then
    rm -rf "$tmp"
    printf '%scommand succeeded; no fix needed\n' "$prefix" >&2
    return 3
  fi

  __lmline_write_fix_input "$tmp/line" "$line" "$status" "$tmp/stdout" "$tmp/stderr"
  __lmline_context_file "$tmp/context" "$line"
  "$engine" --mode fix --shell "$shell_name" --cwd "$PWD" --point "$point" \
    --line-file "$tmp/line" --context-file "$tmp/context" --n "$n" >"$tmp/engine" 2>&1
  engine_status=$?
  if (( engine_status != 0 )); then
    cat "$tmp/engine" >&2
    rm -rf "$tmp"
    return "$engine_status"
  fi
  # Engine output is already validated, deduplicated, and risk-annotated.
  grep '^lmline-candidate: \|^lmline-status: ' "$tmp/engine" || true
  rm -rf "$tmp"
}
