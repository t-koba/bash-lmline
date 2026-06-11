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

__lmline_zsh_load_all_config() {
  local exports line
  exports=$(LMLINE_CONFIG_DIR=$LMLINE_CONFIG_DIR bash -c '
    source "$1/config.bash"
    __lmline_load_all_config
    env | awk -F= "/^LMLINE_[A-Z0-9_]*=/ { print }"
  ' _ "$LMLINE_DIR") || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == LMLINE_*=* ]] && typeset -gx "$line"
  done <<<"$exports"
}

__lmline_zsh_load_all_config

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
typeset -g LMLINE_PS0=${LMLINE_PS0:-'🍋‍🟩 '}

typeset -ga __LMLINE_ZSH_CANDIDATES
typeset -ga __LMLINE_ZSH_RISKS
typeset -ga __LMLINE_ZSH_REASONS
typeset -ga __LMLINE_ZSH_FLAGS
typeset -gi __LMLINE_ZSH_INDEX=1
typeset -g __LMLINE_ZSH_LAST_ORIGINAL=
typeset -g __LMLINE_ZSH_LAST_MODE=
typeset -g __LMLINE_ZSH_LAST_SUGGESTION_ID=
typeset -g __LMLINE_ZSH_ASYNC_KEY=
typeset -g __LMLINE_ZSH_ASYNC_FILE=
typeset -gi __LMLINE_ZSH_ASYNC_PID=0
typeset -gi __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
typeset -g __LMLINE_ZSH_STATUS_LINE=

__lmline_zsh_async_cleanup() {
  [[ -n "${__LMLINE_ZSH_ASYNC_FILE:-}" ]] || return 0
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

__lmline_zsh_strip_progress_lines() {
  sed '/^lmline-progress: /d; /^lmline-meta: /d; /^lmline-status: /d'
}

# The engine emits one preformatted "lmline-status:" line; display it verbatim.
__lmline_zsh_read_meta() {
  local file=$1
  __LMLINE_ZSH_STATUS_LINE=
  [[ -f "$file" ]] || return 0
  __LMLINE_ZSH_STATUS_LINE=$(awk '/^lmline-status: / { sub(/^lmline-status: /, ""); last=$0 } END { print last }' "$file" 2>/dev/null)
}

__lmline_zsh_meta_status() {
  print -nr -- "$__LMLINE_ZSH_STATUS_LINE"
}

# Parses "lmline-candidate:" protocol lines into the candidate arrays. The
# engine owns validation and risk classification.
__lmline_zsh_set_candidates() {
  local output=$1 payload risk reason flags candidate rest
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
  local pid=$1 label=$2 progress_file=${3:-} frame_index=1 tick=0 elapsed=0 interval=${LMLINE_SPINNER_INTERVAL:-0.2} current_label
  local -a frames=('.  ' '.. ' '...')
  if ! __lmline_zsh_spinner_enabled; then
    wait "$pid"
    return $?
  fi
  while kill -0 "$pid" 2>/dev/null; do
    current_label=$(__lmline_zsh_progress_label "$progress_file" "$label")
    __lmline_zsh_hint "${LMLINE_PS0}${current_label}${frames[$frame_index]} ${elapsed}s"
    sleep "$interval"
    frame_index=$(( (frame_index % ${#frames[@]}) + 1 ))
    tick=$((tick + 1))
    (( tick % 5 == 0 )) && elapsed=$((elapsed + 1))
  done
  wait "$pid"
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
  local line=$1
  local trimmed=${line%"${line##*[![:space:]]}"}
  case "$line" in
    '# '*|'#'*|'?'|'? '*) print -r -- generate ;;
    '') print -r -- generate ;;
    *)
      case "$trimmed" in
        *'|'|*'||'|*'&&'|*';'|*'>'|*'>>'|*'\\') print -r -- continue ;;
        *) print -r -- rewrite ;;
      esac
      ;;
  esac
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
  __lmline_zsh_wait_with_spinner "$pid" "$label" "$output_file"
  __LMLINE_ZSH_BRIDGE_STATUS=$?
  __lmline_zsh_clear_hint
  __lmline_zsh_read_meta "$output_file"
  (( had_monitor == 1 )) && setopt monitor
  __LMLINE_ZSH_BRIDGE_OUTPUT=$(__lmline_zsh_strip_progress_lines <"$output_file" 2>/dev/null)
  rm -rf "$tmp"
  return "$__LMLINE_ZSH_BRIDGE_STATUS"
}

__lmline_zsh_bridge() {
  local action=$1 mode=${2-} line=${3-} point=${4-0}
  LMLINE_DIR=$LMLINE_DIR \
  LMLINE_ENGINE=$LMLINE_ENGINE \
  LMLINE_HISTORY_DIR=$LMLINE_HISTORY_DIR \
  LMLINE_CONFIG_DIR=$LMLINE_CONFIG_DIR \
  LMLINE_CANDIDATE_COUNT=$LMLINE_CANDIDATE_COUNT \
  LMLINE_MAX_CANDIDATE_BYTES=${LMLINE_MAX_CANDIDATE_BYTES:-4096} \
  LMLINE_PS0=$LMLINE_PS0 \
    bash -c '
    set -u
    set -o pipefail
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
        printf "%s" "$line" >"$tmp/line"
        __lmline_context_file "$tmp/context" "$line"
        engine_file="$tmp/engine"
        "$LMLINE_ENGINE" --mode "$mode" --shell zsh --cwd "$PWD" --point "$point" --line-file "$tmp/line" --context-file "$tmp/context" --n "$LMLINE_CANDIDATE_COUNT" >"$engine_file"
        status=$?
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
  ' _ "$action" "$mode" "$line" "$point"
}

__lmline_zsh_request_key() {
  local mode=$1 line=$2
  LMLINE_PROMPT_VERSION=${LMLINE_PROMPT_VERSION:-1} bash -c '
    source "$1/context.bash"
    __lmline_request_key "$2" "$3"
  ' _ "$LMLINE_DIR" "$mode" "$line"
}

__lmline_zsh_load_candidates_from_file() {
  local file=$1 output
  output=$(cat "$file" 2>/dev/null)
  __lmline_zsh_set_candidates "$output"
}

__lmline_zsh_async_start() {
  local mode=$1 line=$2 point=$3 async_file=$4 async_status_file tmp_out key
  __lmline_zsh_async_cleanup
  key=$(__lmline_zsh_request_key "$mode" "$line")
  async_status_file=$async_file.status
  tmp_out=$async_file.tmp.$$
  rm -f "$async_status_file" "$async_status_file.err" "$tmp_out" "$async_file"
  (
    if __lmline_zsh_bridge generate "$mode" "$line" "$point" >"$tmp_out" 2>"$async_status_file.err" && [[ -s "$tmp_out" ]]; then
      mv "$tmp_out" "$async_file"
      print -r -- ok >"$async_status_file"
    else
      rm -f "$tmp_out" "$async_file"
      print -r -- failed >"$async_status_file"
    fi
  ) &
  __LMLINE_ZSH_ASYNC_PID=$!
  disown $__LMLINE_ZSH_ASYNC_PID 2>/dev/null || true
  __LMLINE_ZSH_ASYNC_KEY=$key
  __LMLINE_ZSH_ASYNC_FILE=$async_file
}

__lmline_zsh_generate_async() {
  local original=$1 mode=$2 point=$3 async_file current_key async_status_file err_msg
  current_key=$(__lmline_zsh_request_key "$mode" "$original")

  if [[ "$__LMLINE_ZSH_ASYNC_KEY" == "$current_key" && $__LMLINE_ZSH_ASYNC_PID -gt 0 ]]; then
    async_file=$__LMLINE_ZSH_ASYNC_FILE
    if kill -0 "$__LMLINE_ZSH_ASYNC_PID" 2>/dev/null; then
      __lmline_zsh_hint "${LMLINE_PS0}[$mode] still generating..."
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
  __lmline_zsh_async_start "$mode" "$original" "$point" "$async_file"
  __lmline_zsh_hint "${LMLINE_PS0}[$mode] started; press generate key again to insert"
  zle redisplay 2>/dev/null || true
}

__lmline_zsh_record_suggestion() {
  local mode=$1 original=$2 candidate=$3 id timestamp
  id=$(date -u +%Y%m%d%H%M%S 2>/dev/null || print '0')-$$
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || print 'unknown')
  __LMLINE_ZSH_LAST_SUGGESTION_ID=$id
  command mkdir -p "$LMLINE_HISTORY_DIR" 2>/dev/null || return 0
  {
    print "id=${(q)id}"
    print "timestamp=${(q)timestamp}"
    print "cwd=${(q)PWD}"
    print "mode=${(q)mode}"
    print "original=${(q)original}"
    print "candidate=${(q)candidate}"
  } >>"$LMLINE_HISTORY_DIR/suggestions.log" 2>/dev/null || true
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
  [[ "$flags" == *truncated* || "$candidate" == "# TRUNCATED: "* ]] && truncated=1
  if [[ "${__LMLINE_ZSH_LAST_MODE:-}" == rewrite && "$candidate" == "${__LMLINE_ZSH_LAST_ORIGINAL:-}" ]]; then
    BUFFER=$candidate
    CURSOR=${#BUFFER}
    (( __LMLINE_ZSH_SHOW_CANDIDATE_COUNT == 1 && n > 1 )) && __lmline_zsh_hint "${LMLINE_PS0}${n} candidates$(__lmline_zsh_meta_status | sed 's/^/; /')" || __lmline_zsh_clear_hint
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
      else
        (( __LMLINE_ZSH_SHOW_CANDIDATE_COUNT == 1 && n > 1 )) && __lmline_zsh_hint "${LMLINE_PS0}${n} candidates$(__lmline_zsh_meta_status | sed 's/^/; /')" || __lmline_zsh_clear_hint
      fi
      ;;
  esac
  __LMLINE_ZSH_SHOW_CANDIDATE_COUNT=0
  CURSOR=${#BUFFER}
  __lmline_zsh_record_suggestion "${__LMLINE_ZSH_LAST_MODE:-unknown}" "${__LMLINE_ZSH_LAST_ORIGINAL:-}" "$candidate"
  zle redisplay 2>/dev/null || true
}

__lmline_zsh_bridge_candidates() {
  local label=$1 action=$2 mode=$3 line=$4 point=$5 bridge_status output
  __lmline_zsh_run_bridge "$label" "$action" "$mode" "$line" "$point"
  bridge_status=$?
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

_lmline() {
  local cmd
  if command -v lmline >/dev/null 2>&1; then
    cmd=lmline
  else
    cmd="$LMLINE_DIR/lmline"
  fi
  case $CURRENT in
    2)
      compadd config history explain clip doctor risk help debug disable enable endpoint model use current complete
      ;;
    3)
      case $words[2] in
        use) compadd -- "${(@f)$($cmd complete endpoints 2>/dev/null)}" ;;
        clip) compadd -- --status --providers --use --provider ;;
        endpoint) compadd add list set-secret remove ;;
        model) compadd add list refresh remove ;;
        config) compadd get set unset project-get project-set project-unset ;;
        history) compadd show tendencies ;;
        debug) compadd bindings on off trace ;;
      esac
      ;;
    4)
      case "$words[2]:$words[3]" in
        use:*) compadd -- "${(@f)$($cmd complete models "$words[3]" 2>/dev/null)}" ;;
        clip:--use|clip:--provider) compadd -- "${(@f)$($cmd complete clipboard-providers 2>/dev/null)}" ;;
        endpoint:set-secret|endpoint:remove) compadd -- "${(@f)$($cmd complete endpoints 2>/dev/null)}" ;;
        model:add|model:list|model:refresh|model:remove) compadd -- "${(@f)$($cmd complete endpoints 2>/dev/null)}" ;;
      esac
      ;;
    5)
      case "$words[2]:$words[3]" in
        model:remove) compadd -- "${(@f)$($cmd complete models "$words[4]" 2>/dev/null)}" ;;
      esac
      ;;
  esac
}
compdef _lmline lmline 2>/dev/null || true

if [[ "${LMLINE_BIND_KEYS:-1}" == 1 ]]; then
  for pair in \
    "${LMLINE_KEY_GENERATE}:lmline-zsh-generate-widget" "${LMLINE_KEY_REWRITE}:lmline-zsh-rewrite-widget" \
    "${LMLINE_KEY_NEXT}:lmline-zsh-next-widget" "${LMLINE_KEY_PREV}:lmline-zsh-prev-widget" \
    "${LMLINE_KEY_EXPLAIN}:lmline-zsh-explain-widget" "${LMLINE_KEY_FIX}:lmline-zsh-fix-widget" \
    "${LMLINE_KEY_CLIP}:lmline-zsh-clip-widget"; do
    bindkey "${pair%%:*}" "${pair#*:}"
  done
fi
