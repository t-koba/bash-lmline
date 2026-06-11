#!/usr/bin/env bash

if [[ -z "${BASH_VERSION-}" ]]; then
  printf 'lmline: init.bash requires interactive bash/readline; start bash before sourcing it.\n' >&2
  return 0 2>/dev/null || exit 0
fi
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  printf 'lmline: init.bash requires bash 4.2 or newer; current version is %s.\n' "$BASH_VERSION" >&2
  return 0 2>/dev/null || exit 0
fi

[[ $- == *i* ]] || return 0

if ! command -v bind >/dev/null 2>&1; then
  printf 'lmline: bash readline builtin "bind" is unavailable in this shell.\n' >&2
  return 0
fi

__LMLINE_DIR=${BASH_SOURCE[0]%/*}
if [[ $__LMLINE_DIR == "${BASH_SOURCE[0]}" ]]; then
  __LMLINE_DIR=.
fi
__LMLINE_DIR=$(cd -- "$__LMLINE_DIR" && pwd -P)

__LMLINE_CONFIG_DIR=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}
# shellcheck source=lmline/config.bash
source "$__LMLINE_DIR/config.bash"
__lmline_load_all_config

: "${LMLINE_ENGINE:=$__LMLINE_DIR/engine}"
: "${LMLINE_HISTORY_DIR:=$__LMLINE_CONFIG_DIR/history}"
: "${LMLINE_BIND_KEYS:=1}"
: "${LMLINE_ASYNC:=0}"
: "${LMLINE_EXPERIMENTAL_DEFAULT_COMPLETION:=0}"
: "${LMLINE_STATUS_MODE:=inline}"
: "${LMLINE_SPINNER:=1}"
: "${LMLINE_SPINNER_INTERVAL:=0.2}"
: "${LMLINE_DEBUG:=0}"
: "${LMLINE_CANDIDATE_COUNT:=3}"
: "${LMLINE_KEY_GENERATE:=\C-x\C-g}"
: "${LMLINE_KEY_REWRITE:=\C-x\C-r}"
: "${LMLINE_KEY_NEXT:=\C-x\C-n}"
: "${LMLINE_KEY_PREV:=\C-x\C-p}"
: "${LMLINE_KEY_EXPLAIN:=\C-x\C-e}"
: "${LMLINE_KEY_FIX:=\C-x\C-f}"
: "${LMLINE_KEY_CLIP:=\C-x\C-v}"
: "${LMLINE_FIX_TIMEOUT:=12}"
: "${LMLINE_FIX_MAX_OUTPUT:=12000}"
: "${LMLINE_FIX_ALLOW_MEDIUM:=0}"
: "${LMLINE_PS0:=🍋‍🟩 }"


# shellcheck source=lmline/context.bash
source "$__LMLINE_DIR/context.bash"
# shellcheck source=lmline/policy.bash
source "$__LMLINE_DIR/policy.bash"
# shellcheck source=lmline/actions.bash
source "$__LMLINE_DIR/actions.bash"

declare -ga __LMLINE_CANDIDATES=()
declare -ga __LMLINE_CANDIDATE_RISKS=()
declare -ga __LMLINE_CANDIDATE_REASONS=()
declare -ga __LMLINE_CANDIDATE_FLAGS=()
declare -gi __LMLINE_INDEX=0
declare -g __LMLINE_LAST_MODE=""
declare -g __LMLINE_LAST_ORIGINAL=""
declare -g __LMLINE_LAST_SUGGESTION_ID=""
declare -gi __LMLINE_ENGINE_STATUS=0
declare -g __LMLINE_ENGINE_ERROR=""
declare -g __LMLINE_ENGINE_OUTPUT=""
declare -g __LMLINE_ENGINE_STATUS_LINE=""
declare -g __LMLINE_ASYNC_KEY=""
declare -g __LMLINE_ASYNC_FILE=""
declare -g __LMLINE_ASYNC_MODE=""
declare -gi __LMLINE_ASYNC_POINT=0
declare -gi __LMLINE_ASYNC_PID=0
declare -gi __LMLINE_SHOW_CANDIDATE_COUNT=0


__lmline_hint() {
  local action=$1 msg=${2-}
  case "${LMLINE_STATUS_MODE:-inline}" in
    log|debug) [[ -n "$msg" ]] && printf '%s\n' "$msg" >&2 ;;
    silent|none) ;;
    transient) [[ "$action" == clear || "$action" == final ]] && printf '\r\033[K' >&2 || printf '\r\033[K%s' "$msg" >&2 ;;
    *) case "$action" in
        show) printf '\r\033[K%s' "$msg" >&2 ;;
        final) printf '\r\033[K%s\n' "$msg" >&2 ;;
        clear) printf '\r\033[K' >&2 ;;
      esac ;;
  esac
}

__lmline_candidate_position_hint() {
  local count=$1 detail=""
  (( count > 1 )) || return 0
  detail=$(__lmline_engine_meta_status)
  case "${LMLINE_STATUS_MODE:-inline}" in
    log|debug) printf '%s%s candidates%s\n' "$LMLINE_PS0" "$count" "${detail:+; $detail}" >&2 ;;
    silent|none) ;;
    *) printf '\n%s%s candidates%s\n' "$LMLINE_PS0" "$count" "${detail:+; $detail}" >&2 ;;
  esac
}

__lmline_candidate_notice() {
  local msg=$1
  case "${LMLINE_STATUS_MODE:-inline}" in
    silent|none) ;;
    log|debug) [[ -n "$msg" ]] && printf '%s\n' "$msg" >&2 ;;
    *) [[ -n "$msg" ]] && printf '\n%s\n' "$msg" >&2 ;;
  esac
}

__lmline_spinner_enabled() {
  [[ "${LMLINE_SPINNER:-1}" == 1 && -t 2 ]] || return 1
  case "${LMLINE_STATUS_MODE:-inline}" in
    inline|transient) return 0 ;;
    *) return 1 ;;
  esac
}

__lmline_progress_label() {
  local file=$1 fallback=$2 label
  if [[ -f "$file" ]]; then
    label=$(awk '/^lmline-progress: / { sub(/^lmline-progress: /, ""); last=$0 } END { print last }' "$file" 2>/dev/null)
  fi
  printf '%s' "${label:-$fallback}"
}

__lmline_strip_progress_lines() {
  sed '/^lmline-progress: /d; /^lmline-meta: /d; /^lmline-status: /d'
}

# The engine emits one preformatted "lmline-status:" line; display it verbatim.
__lmline_read_engine_meta() {
  local file=$1
  __LMLINE_ENGINE_STATUS_LINE=""
  [[ -f "$file" ]] || return 0
  __LMLINE_ENGINE_STATUS_LINE=$(awk '/^lmline-status: / { sub(/^lmline-status: /, ""); last=$0 } END { print last }' "$file" 2>/dev/null)
}

__lmline_engine_meta_status() {
  printf '%s' "$__LMLINE_ENGINE_STATUS_LINE"
}

# Parses "lmline-candidate:" protocol lines from stdin into the candidate
# arrays. The engine owns validation and risk classification; this keeps only
# a control-character defense and dedupe.
__lmline_parse_candidates() {
  local payload risk reason flags candidate existing seen
  __LMLINE_CANDIDATES=()
  __LMLINE_CANDIDATE_RISKS=()
  __LMLINE_CANDIDATE_REASONS=()
  __LMLINE_CANDIDATE_FLAGS=()
  while IFS= read -r payload; do
    [[ "$payload" == 'lmline-candidate: '* ]] || continue
    payload=${payload#lmline-candidate: }
    IFS=$'\t' read -r risk reason flags candidate <<<"$payload"
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" != *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']* ]] || continue
    case "$risk" in
      high|medium|low) ;;
      *) risk=high; reason='unknown risk annotation' ;;
    esac
    seen=0
    for existing in ${__LMLINE_CANDIDATES[@]+"${__LMLINE_CANDIDATES[@]}"}; do
      [[ "$existing" == "$candidate" ]] && { seen=1; break; }
    done
    (( seen == 1 )) && continue
    __LMLINE_CANDIDATES+=("$candidate")
    __LMLINE_CANDIDATE_RISKS+=("$risk")
    __LMLINE_CANDIDATE_REASONS+=("$reason")
    __LMLINE_CANDIDATE_FLAGS+=("${flags:--}")
  done
}

__lmline_append_original_candidate() {
  local original=$1 candidate
  for candidate in ${__LMLINE_CANDIDATES[@]+"${__LMLINE_CANDIDATES[@]}"}; do
    [[ "$candidate" == "$original" ]] && return 0
  done
  __LMLINE_CANDIDATES+=("$original")
  __LMLINE_CANDIDATE_RISKS+=(low)
  __LMLINE_CANDIDATE_REASONS+=('-')
  __LMLINE_CANDIDATE_FLAGS+=(original)
}

__lmline_wait_with_spinner() {
  local pid=$1 label=$2 progress_file=${3:-} frame_index=0 tick=0 elapsed=0 interval=${LMLINE_SPINNER_INTERVAL:-0.2} current_label
  local -a frames=('.  ' '.. ' '...')
  if ! __lmline_spinner_enabled; then
    wait "$pid"
    return $?
  fi
  while kill -0 "$pid" 2>/dev/null; do
    current_label=$(__lmline_progress_label "$progress_file" "$label")
    __lmline_hint show "${LMLINE_PS0}${current_label}${frames[$frame_index]} ${elapsed}s"
    sleep "$interval"
    frame_index=$(( (frame_index + 1) % ${#frames[@]} ))
    tick=$((tick + 1))
    (( tick % 5 == 0 )) && elapsed=$((elapsed + 1))
  done
  wait "$pid"
}

__lmline_run_internal_job() {
  local label=$1 output_file=$2 had_monitor=0 pid status
  shift 2
  case $- in
    *m*) had_monitor=1; set +m ;;
  esac
  { "$@" >"$output_file" 2>&1 & pid=$!; } 2>/dev/null
  __lmline_wait_with_spinner "$pid" "$label" "$output_file"
  status=$?
  __lmline_hint clear
  (( had_monitor == 1 )) && set -m
  return "$status"
}

__lmline_debug_log() {
  [[ "${LMLINE_DEBUG:-0}" == 1 ]] || return 0
  printf 'lmline debug: %s\n' "$*" >&2
}

__lmline_set_line() {
  local line=$1
  READLINE_LINE=$line
  READLINE_POINT=${#READLINE_LINE}
}

__lmline_infer_mode() {
  local line=$1
  local trimmed=${line%"${line##*[![:space:]]}"}
  case "$line" in
    '#'*|'?'|'? '*)
      printf 'generate'
      ;;
    '')
      printf 'generate'
      ;;
    *)
      case "$trimmed" in
        *'|'|*'||'|*'&&'|*';'|*'>'|*'>>'|*'\\')
          printf 'continue'
          ;;
        *)
          printf 'rewrite'
          ;;
      esac
      ;;
  esac
}

__lmline_call_engine_raw() {
  local mode=$1
  local line=$2
  local point=$3
  local tmp line_file context_file status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-gen.XXXXXX") || return 1
  line_file=$tmp/line
  context_file=$tmp/context
  printf '%s' "$line" >"$line_file"
  __lmline_context_file "$context_file" "$line"

  "$LMLINE_ENGINE" \
    --mode "$mode" \
    --shell bash \
    --cwd "$PWD" \
    --point "$point" \
    --line-file "$line_file" \
    --context-file "$context_file" \
    --n "$LMLINE_CANDIDATE_COUNT"
  status=$?
  rm -rf "$tmp"
  return "$status"
}

__lmline_call_engine() {
  local mode=$1
  local line=$2
  local point=$3
  local label=${4:-generating}
  local output status tmp output_file pid
  __LMLINE_ENGINE_STATUS=0
  __LMLINE_ENGINE_ERROR=""
  __LMLINE_ENGINE_OUTPUT=""
  __LMLINE_ENGINE_STATUS_LINE=""
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-call.XXXXXX") || return 1
  output_file=$tmp/output
  __lmline_run_internal_job "$label" "$output_file" __lmline_call_engine_raw "$mode" "$line" "$point"
  status=$?
  __lmline_read_engine_meta "$output_file"
  output=$(__lmline_strip_progress_lines <"$output_file" 2>/dev/null || true)
  rm -rf "$tmp"
  if (( status == 0 )); then
    __LMLINE_ENGINE_OUTPUT=$output
    printf '%s\n' "$output"
    return 0
  fi
  __LMLINE_ENGINE_STATUS=$status
  if [[ -n "$output" ]]; then
    __LMLINE_ENGINE_ERROR=$(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c 1-300)
    __lmline_debug_log "$__LMLINE_ENGINE_ERROR"
  else
    __LMLINE_ENGINE_ERROR="engine exited with status $status"
  fi
  return "$status"
}

__lmline_run_explain_engine() {
  local engine=$1 shell_name=$2 point=$3 line_file=$4 context_file=$5
  local tmp output_file status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-expl.XXXXXX") || return 1
  output_file=$tmp/output
  __lmline_run_internal_job "explaining" "$output_file" "$engine" --mode explain --shell "$shell_name" --cwd "$PWD" --point "$point" --line-file "$line_file" --context-file "$context_file" --n 1
  status=$?
  cat "$output_file" 2>/dev/null || true
  rm -rf "$tmp"
  return "$status"
}

__lmline_engine_error_hint() {
  __lmline_engine_error_message "$LMLINE_PS0" "${__LMLINE_ENGINE_ERROR:-engine failed}"
}

__lmline_async_cleanup() {
  [[ -n "${__LMLINE_ASYNC_FILE:-}" ]] || return 0
  rm -f "$__LMLINE_ASYNC_FILE" "$__LMLINE_ASYNC_FILE.status" "$__LMLINE_ASYNC_FILE.status.err" "$__LMLINE_ASYNC_FILE.tmp."*
  __LMLINE_ASYNC_FILE=""
  __LMLINE_ASYNC_PID=0
  __LMLINE_ASYNC_KEY=""
}

__lmline_async_start() {
  local mode=$1 line=$2 point=$3 async_file=$4 async_status_file tmp_out
  __lmline_async_cleanup
  async_status_file=$async_file.status
  tmp_out=$async_file.tmp.$$
  rm -f "$async_status_file" "$tmp_out"
  (
    if __lmline_call_engine_raw "$mode" "$line" "$point" >"$tmp_out" 2>"$async_status_file.err"; then
      mv "$tmp_out" "$async_file"
      printf 'ok\n' >"$async_status_file"
    else
      rm -f "$tmp_out"
      printf 'failed\n' >"$async_status_file"
    fi
  ) &
  __LMLINE_ASYNC_PID=$!
  __LMLINE_ASYNC_KEY=$(__lmline_request_key "$mode" "$line")
  __LMLINE_ASYNC_FILE=$async_file
  __LMLINE_ASYNC_MODE=$mode
  __LMLINE_ASYNC_POINT=$point
}

__lmline_load_candidates_from_file() {
  local file=$1
  __lmline_parse_candidates <"$file"
  if [[ "${__LMLINE_ASYNC_MODE:-}" == rewrite && -n "${__LMLINE_LAST_ORIGINAL:-}" ]]; then
    __lmline_append_original_candidate "$__LMLINE_LAST_ORIGINAL"
  fi
}

__lmline_record_suggestion() {
  local mode=$1 original=$2 candidate=$3
  mkdir -p "$LMLINE_HISTORY_DIR" 2>/dev/null || true
  __LMLINE_LAST_SUGGESTION_ID=$(date +%Y%m%d%H%M%S)-$$
  {
    printf 'id=%q\n' "$__LMLINE_LAST_SUGGESTION_ID"
    printf 'timestamp=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cwd=%q\n' "$PWD"
    printf 'mode=%q\n' "$mode"
    printf 'original=%q\n' "$original"
    printf 'candidate=%q\n' "$candidate"
  } >>"$LMLINE_HISTORY_DIR/suggestions.log" 2>/dev/null || true
}

# Applies the candidate at the given index using the engine's risk/flag
# annotations; no local risk re-evaluation.
__lmline_apply_candidate() {
  local idx=$1
  local cmd=${__LMLINE_CANDIDATES[$idx]}
  local risk=${__LMLINE_CANDIDATE_RISKS[$idx]:-high}
  local reason=${__LMLINE_CANDIDATE_REASONS[$idx]:--}
  local flags=${__LMLINE_CANDIDATE_FLAGS[$idx]:--}
  local n=${#__LMLINE_CANDIDATES[@]} pos=$((idx + 1)) truncated=0
  [[ "$flags" == *truncated* || "$cmd" == "# TRUNCATED: "* ]] && truncated=1
  if [[ "${__LMLINE_LAST_MODE:-}" == rewrite && "$cmd" == "${__LMLINE_LAST_ORIGINAL:-}" ]]; then
    __lmline_set_line "$cmd"
    (( __LMLINE_SHOW_CANDIDATE_COUNT == 1 )) && __lmline_candidate_position_hint "$n" || __lmline_hint clear
    __LMLINE_SHOW_CANDIDATE_COUNT=0
    return 0
  fi
  case "$risk" in
    high)
      __lmline_set_line "# REVIEW REQUIRED: $cmd"
      __lmline_candidate_notice "${LMLINE_PS0}${pos}/${n} high-risk; inserted as comment ($reason)"
      ;;
    medium)
      __lmline_set_line "$cmd"
      __lmline_candidate_notice "${LMLINE_PS0}${pos}/${n} medium-risk; review before Enter ($reason)"
      ;;
    low)
      __lmline_set_line "$cmd"
      if (( truncated == 1 )); then
        __lmline_candidate_notice "${LMLINE_PS0}${pos}/${n} candidate-truncated to ${LMLINE_MAX_CANDIDATE_BYTES:-4096} bytes"
      else
        (( __LMLINE_SHOW_CANDIDATE_COUNT == 1 )) && __lmline_candidate_position_hint "$n" || __lmline_hint clear
      fi
      ;;
  esac
  __LMLINE_SHOW_CANDIDATE_COUNT=0
  __lmline_record_suggestion "${__LMLINE_LAST_MODE:-unknown}" "${__LMLINE_LAST_ORIGINAL:-}" "$cmd"
}

__lmline_select_candidate() {
  local selected
  local -a selector_words
  if [[ -n "${LMLINE_SELECTOR:-}" && ${#__LMLINE_CANDIDATES[@]} -gt 1 ]]; then
    read -r -a selector_words <<<"$LMLINE_SELECTOR"
    if ((${#selector_words[@]})); then
      if ! command -v "${selector_words[0]}" >/dev/null 2>&1; then
        __lmline_hint show "${LMLINE_PS0}selector unavailable: ${selector_words[0]}; using first candidate"
      elif selected=$(printf '%s\n' "${__LMLINE_CANDIDATES[@]}" | "${selector_words[@]}"); then
        if [[ -n "$selected" ]]; then
          printf '%s\n' "$selected"
          return 0
        fi
        __lmline_hint show "${LMLINE_PS0}selector returned no candidate; using first candidate"
      else
        __lmline_hint show "${LMLINE_PS0}selector failed; using first candidate"
      fi
    fi
  fi
  printf '%s\n' "${__LMLINE_CANDIDATES[0]}"
}

__lmline_load_candidates() {
  local mode=$1 original=$2 point=$3 label=${4:-generating} engine_status
  __LMLINE_CANDIDATES=()
  __lmline_call_engine "$mode" "$original" "$point" "$label" >/dev/null
  engine_status=$?
  if (( engine_status != 0 )); then
    return "$engine_status"
  fi
  __lmline_parse_candidates <<<"$__LMLINE_ENGINE_OUTPUT"
  if [[ "$mode" == rewrite ]]; then
    __lmline_append_original_candidate "$original"
  fi
}

__lmline_complete_generation() {
  local selected i
  if ((${#__LMLINE_CANDIDATES[@]} == 0)); then
    __lmline_hint final "${LMLINE_PS0}no candidate"
    return 0
  fi
  selected=$(__lmline_select_candidate)
  __LMLINE_SHOW_CANDIDATE_COUNT=1
  __LMLINE_INDEX=0
  for ((i = 0; i < ${#__LMLINE_CANDIDATES[@]}; i++)); do
    [[ "${__LMLINE_CANDIDATES[$i]}" == "$selected" ]] && { __LMLINE_INDEX=$i; break; }
  done
  # In rewrite mode the original line is appended as a cycling target only;
  # prefer a real suggestion for the first insertion.
  if [[ "$selected" == "${__LMLINE_LAST_ORIGINAL:-}" ]]; then
    selected=""
    for ((i = 0; i < ${#__LMLINE_CANDIDATES[@]}; i++)); do
      if [[ "${__LMLINE_CANDIDATES[$i]}" != "${__LMLINE_LAST_ORIGINAL:-}" ]]; then
        __LMLINE_INDEX=$i
        selected=${__LMLINE_CANDIDATES[$i]}
        break
      fi
    done
    if [[ -z "$selected" ]]; then
      if [[ "${__LMLINE_LAST_MODE:-}" == rewrite ]]; then
        __lmline_hint final "${LMLINE_PS0}no rewrite candidate"
      else
        __lmline_hint final "${LMLINE_PS0}no valid candidate"
      fi
      return 0
    fi
  fi
  __lmline_apply_candidate "$__LMLINE_INDEX"
}

__lmline_generate_async_widget() {
  local original=$1 mode=$2 point=$3 async_file current_key async_status_file
  current_key=$(__lmline_request_key "$mode" "$original")

  if [[ "$__LMLINE_ASYNC_KEY" == "$current_key" && $__LMLINE_ASYNC_PID -gt 0 ]]; then
    async_file=$__LMLINE_ASYNC_FILE
    if kill -0 "$__LMLINE_ASYNC_PID" 2>/dev/null; then
      __lmline_hint show "${LMLINE_PS0}[$mode] still generating..."
      return 0
    fi
    if [[ -s "$async_file" ]]; then
      __lmline_hint clear
      __lmline_read_engine_meta "$async_file.status.err"
      __lmline_load_candidates_from_file "$async_file"
      __lmline_complete_generation
      __lmline_async_cleanup
      return 0
    fi
    if [[ -f "$async_file.status.err" ]]; then
      __LMLINE_ENGINE_ERROR=$(cut -c 1-200 "$async_file.status.err")
      __lmline_hint show "$(__lmline_engine_error_hint)"
    else
      __lmline_hint show "${LMLINE_PS0}async generation failed"
    fi
    __lmline_async_cleanup
    return 0
  fi

  __lmline_async_cleanup
  async_file=$(mktemp "${TMPDIR:-/tmp}/lmline-async.XXXXXX") || {
    __lmline_hint final "${LMLINE_PS0}async temp file failed"
    return 0
  }
  __lmline_async_start "$mode" "$original" "$point" "$async_file"
  __lmline_hint show "${LMLINE_PS0}[$mode] started; press generate key again to insert"
}

__lmline_generate_or_rewrite() {
  local mode=$1 original
  original=$READLINE_LINE
  if [[ "$mode" == rewrite && -z "${original//[[:space:]]/}" ]]; then
    __lmline_hint final "${LMLINE_PS0}no command to rewrite"
    return 0
  fi
  __LMLINE_LAST_ORIGINAL=$original
  __LMLINE_LAST_MODE=$mode
  __LMLINE_INDEX=0
  if [[ "${LMLINE_ASYNC:-0}" == 1 ]]; then
    __lmline_generate_async_widget "$original" "$mode" "$READLINE_POINT"
    return 0
  fi
  if ! __lmline_load_candidates "$mode" "$original" "$READLINE_POINT" "[$mode]"; then
    __lmline_hint final "$(__lmline_engine_error_hint)"
    return 0
  fi
  __lmline_complete_generation
}

__lmline_generate_widget() {
  __lmline_generate_or_rewrite "$(__lmline_infer_mode "$READLINE_LINE")"
}

__lmline_rewrite_widget() {
  __lmline_generate_or_rewrite rewrite
}

__lmline_fix_widget() {
  local original=$READLINE_LINE tmp engine_output engine_status
  [[ -n "$original" ]] || {
    __lmline_hint final "${LMLINE_PS0}no command to fix"
    return 0
  }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-fix.XXXXXX") || return 1
  __LMLINE_LAST_ORIGINAL=$original
  __LMLINE_LAST_MODE=fix
  __LMLINE_INDEX=0
  __LMLINE_ENGINE_OUTPUT=""
  __lmline_run_internal_job "fixing command" "$tmp/engine" __lmline_fix_run "$original" bash "${#original}" "$LMLINE_ENGINE" "$LMLINE_CANDIDATE_COUNT" "$LMLINE_PS0"
  engine_status=$?
  __lmline_read_engine_meta "$tmp/engine"
  engine_output=$(__lmline_strip_progress_lines <"$tmp/engine" 2>/dev/null || true)
  if (( engine_status == 3 )); then
    rm -rf "$tmp"
    __lmline_hint final "$(printf '%s' "$engine_output" | sed -n '1p')"
    return 0
  fi
  if (( engine_status != 0 )); then
    __LMLINE_ENGINE_STATUS=$engine_status
    __LMLINE_ENGINE_ERROR=$(printf '%s' "$engine_output" | tr '\n' ' ' | sed 's/[[:space:]]*$//' | cut -c 1-300)
    rm -rf "$tmp"
    __lmline_hint final "$(__lmline_engine_error_hint)"
    return 0
  fi
  __lmline_parse_candidates <<<"$engine_output"
  rm -rf "$tmp"
  __lmline_complete_generation
}

__lmline_next_widget() {
  local n=${#__LMLINE_CANDIDATES[@]}
  (( n > 0 )) || return 0
  __LMLINE_SHOW_CANDIDATE_COUNT=0
  __LMLINE_INDEX=$(( (__LMLINE_INDEX + 1) % n ))
  __lmline_apply_candidate "$__LMLINE_INDEX"
}

__lmline_prev_widget() {
  local n=${#__LMLINE_CANDIDATES[@]}
  (( n > 0 )) || return 0
  __LMLINE_SHOW_CANDIDATE_COUNT=0
  __LMLINE_INDEX=$(( (__LMLINE_INDEX + n - 1) % n ))
  __lmline_apply_candidate "$__LMLINE_INDEX"
}

__lmline_explain_widget() {
  local target
  target=${READLINE_LINE:-${__LMLINE_CANDIDATES[$__LMLINE_INDEX]-}}
  __lmline_print_explanation "$LMLINE_ENGINE" bash "$target" "${#target}" "$LMLINE_PS0" >&2 || return 0
}

__lmline_clip_widget() {
  __lmline_print_clip "$LMLINE_ENGINE" bash "" "$LMLINE_PS0" >&2 || return 0
}

__lmline_cli_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local prev=${COMP_WORDS[COMP_CWORD-1]}
  local subcommands="config history explain clip doctor risk help debug disable enable endpoint model use current complete"
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == use && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete endpoints 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == use && $COMP_CWORD == 3 ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete models "${COMP_WORDS[2]}" 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == clip && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "--status --providers --use --provider" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == clip && $COMP_CWORD == 3 && ${prev} =~ ^(--use|--provider)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete clipboard-providers 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == endpoint && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "add list set-secret remove" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == endpoint && $COMP_CWORD == 3 && ${COMP_WORDS[2]} =~ ^(set-secret|remove)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete endpoints 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == model && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "add list refresh remove" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == model && $COMP_CWORD == 3 && ${COMP_WORDS[2]} =~ ^(add|list|refresh|remove)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete endpoints 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == model && $COMP_CWORD == 4 && ${COMP_WORDS[2]} == remove ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete models "${COMP_WORDS[3]}" 2>/dev/null)" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == config && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "get set unset project-get project-set project-unset" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == history && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "show tendencies" -- "$cur") )
  elif [[ ${COMP_WORDS[1]} == debug && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "bindings on off trace" -- "$cur") )
  fi
}

__lmline_default_completion() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  COMPREPLY=()
  [[ -n "$cur" ]] || return 0
  COMPREPLY=( $(compgen -A command -- "$cur") )
}

if [[ "${LMLINE_BIND_KEYS:-1}" == 1 ]]; then
  for pair in \
    "${LMLINE_KEY_GENERATE}:__lmline_generate_widget" "${LMLINE_KEY_REWRITE}:__lmline_rewrite_widget" \
    "${LMLINE_KEY_NEXT}:__lmline_next_widget" "${LMLINE_KEY_PREV}:__lmline_prev_widget" \
    "${LMLINE_KEY_EXPLAIN}:__lmline_explain_widget" "${LMLINE_KEY_FIX}:__lmline_fix_widget" \
    "${LMLINE_KEY_CLIP}:__lmline_clip_widget"; do
    bind -x "\"${pair%%:*}\": ${pair#*:}"
  done
fi

complete -F __lmline_cli_complete lmline 2>/dev/null || true
if [[ "${LMLINE_EXPERIMENTAL_DEFAULT_COMPLETION:-0}" == 1 ]]; then
  complete -D -F __lmline_default_completion -o bashdefault -o default 2>/dev/null || true
fi
