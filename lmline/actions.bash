#!/usr/bin/env bash

# User-facing lmline actions that call the engine. This file is meant to be sourced
# after config.bash, policy.bash, and context.bash.

__LMLINE_ACTIONS_DIR=${BASH_SOURCE[0]%/*}
[[ $__LMLINE_ACTIONS_DIR == "${BASH_SOURCE[0]}" ]] && __LMLINE_ACTIONS_DIR=.
if [[ ${__LMLINE_DIR-} != "$__LMLINE_ACTIONS_DIR" ]]; then
  __LMLINE_ACTIONS_DIR=$(cd -- "$__LMLINE_ACTIONS_DIR" && pwd -P)
fi
if ! declare -F __lmline_tmp_root >/dev/null 2>&1; then
  # shellcheck source=lmline/config.bash
  source "$__LMLINE_ACTIONS_DIR/config.bash"
fi
if ! declare -F __lmline_engine_error_message >/dev/null 2>&1; then
  # shellcheck source=lmline/http.bash
  source "$__LMLINE_ACTIONS_DIR/http.bash"
fi

: "${LMLINE_CLIP_USERINFO_MIN:=8}"

__lmline_copilot_client() {
  printf '%s/copilot-client.js\n' "$__LMLINE_ACTIONS_DIR"
}

# Converts Copilot inline edits into the existing annotated candidate protocol.
# The Language Server supplies edits; lmline retains final syntax and risk policy.
__lmline_copilot_candidates() {
  if [[ ${__LMLINE_VALIDATION_ISOLATED-} != 1 ]]; then
    __lmline_validation_run copilot-request "$@"
    return
  fi
  local line=$1 point=$2 shell_name=${3:-bash} mode=${4:-rewrite} context_text=${5:-} client output
  client=$(__lmline_copilot_client)
  command -v node >/dev/null 2>&1 || { printf 'lmline-copilot: Node.js 20.8+ is required; run: lmline copilot setup\n' >&2; return 1; }
  [[ -r "$client" ]] || { printf 'lmline-copilot: client is missing: %s\n' "$client" >&2; return 1; }
  output=$(jq -cn --arg line "$line" --arg cwd "$PWD" --argjson point "$point" --arg mode "$mode" --arg contextText "$context_text" \
    '{line:$line,cwd:$cwd,point:$point,mode:$mode,contextText:$contextText}' | node "$client" edit-json) || return 1
  __lmline_copilot_filter_candidates "$shell_name" "$mode" <<<"$output"
}

# Runs only in the clean validation child, once per provider batch.
__lmline_copilot_filter_candidates() {
  local shell_name=$1 mode=$2 entry token candidate rejection risk reason
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ "$entry" == *$'\t'* ]] || continue
    token=${entry%%$'\t'*}
    candidate=${entry#*$'\t'}
    [[ -n "$candidate" ]] || continue
    __lmline_candidate_truncated "$candidate" && continue
    rejection=$(__lmline_candidate_rejection_reason "$candidate" "$mode" "$shell_name")
    [[ "$rejection" == ok ]] || {
      [[ "${LMLINE_DEBUG:-0}" == 1 ]] && printf 'lmline-copilot: rejected candidate: %s\n' "$rejection" >&2
      continue
    }
    risk=$(__lmline_risk_level "$candidate")
    reason=$(__lmline_risk_reason "$candidate")
    reason=${reason//$'\t'/ }
    printf 'lmline-candidate: %s\t%s\tcopilot:%s\t%s\n' "$risk" "${reason:--}" "${token:--}" "$candidate"
  done
}

__lmline_copilot_accept() {
  local flags=$1 token client pid
  # The flags field holds comma-separated markers, so the copilot marker is
  # present only as a whole one.
  [[ ",$flags," == *,copilot:* ]] || return 0
  token=",$flags"; token=${token#*,copilot:}; token=${token%%,*}
  [[ -n "$token" && "$token" != - ]] || return 0
  client=$(__lmline_copilot_client)
  { node "$client" accept "$token" >/dev/null 2>&1 & pid=$!; } 2>/dev/null
  disown "$pid" 2>/dev/null || true
}

# The engine emits one preformatted "lmline-status:" line; extract it verbatim.
__lmline_action_meta_status() {
  local output=$1
  printf '%s\n' "$output" | awk '/^lmline-status: / { sub(/^lmline-status: /, ""); last=$0 } END { if (last != "") print last }'
}

__lmline_action_strip_runtime_lines() {
  sed '/^lmline-progress: /d; /^lmline-meta: /d; /^lmline-status: /d; /^lmline-search: /d; /^lmline-citation: /d'
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

# Runs the engine in the foreground through the line-flushed answer renderer
# so SSE answer lines appear as they arrive. Returns the engine status; status/meta lines
# are read from the captured stderr file. A renderer failure is not masked:
# engine failure takes precedence, otherwise the renderer status is returned.
__lmline_action_stream_engine() {
  local prefix=$1 stderr_file=$2 engine_status display_status error meta_status
  local -a pipe_status
  shift 2
  engine_status=0; display_status=0
  if "$@" 2>"$stderr_file" | __lmline_display_answer; then
    pipe_status=("${PIPESTATUS[@]}")
    engine_status=${pipe_status[0]}
    display_status=${pipe_status[1]}
  else
    pipe_status=("${PIPESTATUS[@]}")
    engine_status=${pipe_status[0]}
    display_status=${pipe_status[1]}
  fi
  if (( engine_status != 0 )); then
    error=$(__lmline_action_strip_runtime_lines <"$stderr_file" 2>/dev/null | __lmline_display_error_line 300)
    __lmline_engine_error_message "$prefix" "${error:-engine exited with status $engine_status}"
    return "$engine_status"
  fi
  if (( display_status != 0 )); then
    return "$display_status"
  fi
  meta_status=$(__lmline_action_meta_status "$(cat "$stderr_file" 2>/dev/null)")
  [[ -n "$meta_status" ]] && printf '%s%s\n' "$prefix" "$meta_status"
  return 0
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
  local wanted=${LMLINE_CLIPBOARD_PROVIDER:-auto} file line output failure
  local -a fields args failures=()
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
        if [[ "${LMLINE_DEBUG:-0}" == 1 ]]; then
          printf 'lmline: clipboard provider auto-selected: %s\n' "${fields[0]}" >&2
        fi
        printf '%s' "$output"
        return 0
      fi
      failures+=("${fields[0]}: ${output%%$'\n'*}")
    done <"$file"
    for failure in "${failures[@]}"; do
      printf 'lmline: clipboard provider failed: %s\n' "$failure" >&2
    done
    printf 'lmline: no usable clipboard provider; run: lmline clip --providers\n' >&2
    return 1
  fi
  line=$(__lmline_clipboard_provider_line) || return 1
  IFS=$'\t' read -r -a fields <<<"$line"
  __LMLINE_CLIPBOARD_PROVIDER_USED=${fields[0]}
  __LMLINE_CLIPBOARD_COMMAND_USED=${fields[1]}
  args=("${fields[@]:2}")
  "${fields[1]}" "${args[@]}"
}

# Generate the realm shield nonce in the calling shell: RANDOM repeats in
# zsh command substitutions and can be unset, while a counter advanced in
# the parent shell is unique for every clip invocation in both shells.
__lmline_next_realm_shield_prefix() {
  __LMLINE_REALM_SHIELD_SEQ=$(( ${__LMLINE_REALM_SHIELD_SEQ:-0} + 1 ))
  __LMLINE_REALM_SHIELD_PREFIX="@@LMLINE_REALM_SHIELD_$$_${__LMLINE_REALM_SHIELD_SEQ}_"
}

# The @ in the temporary marker is deliberate: later scheme-less rules
# exclude @ so they cannot re-redact a value whose scheme was preserved.
# @-specific rules restore coverage for real credentials beginning with @.
__lmline_redact_clip_text() {
  local auth_prefix auth_scheme auth_scheme_name auth_scheme_dq auth_scheme_sq key_prefix
  local key_prefix_quoted_dq key_prefix_quoted_sq
  local key_word key_name key_prefix_url
  local auth_prefix_escaped_dq auth_prefix_escaped_sq auth_scheme_optional
  local key_prefix_escaped_dq key_prefix_escaped_sq
  local auth_prefix_quoted_dq auth_prefix_quoted_sq auth_marker auth_redacted_value
  local realm_shield_prefix=${1-}
  local encoded_mask cont_token cont_token_lf cont_token_cr cont_token_protect
  local userinfo_min=${LMLINE_CLIP_USERINFO_MIN-8}
  local credential_arguments_file credential_arguments_spec
  [[ -n $realm_shield_prefix ]] || return 1
  if [[ -n ${LMLINE_CREDENTIAL_ARGUMENTS_FILE:-} ]]; then
    credential_arguments_file=$LMLINE_CREDENTIAL_ARGUMENTS_FILE
  else
    credential_arguments_file=${LMLINE_DEFAULTS_DIR:-$__LMLINE_ACTIONS_DIR/defaults}/credential_arguments.tsv
    if [[ -n ${ZSH_VERSION-} && ! -r $credential_arguments_file ]]; then
      # zsh does not populate BASH_SOURCE; %x inside this sourced file names it.
      credential_arguments_file=$(eval 'printf "%s\n" "${${(%):-%x}:A:h}"' 2>/dev/null)/defaults/credential_arguments.tsv
    fi
  fi
  [[ -r $credential_arguments_file ]] || {
    printf 'lmline: credential arguments file is not readable: %s\n' "$credential_arguments_file" >&2
    return 1
  }
  credential_arguments_spec=$(awk -F '\t' '
    function invalid(value) {
      return index(value, "|") > 0 || index(value, ":") > 0
    }
    /^#/ || /^[[:space:]]*$/ { next }
    $1 == "" { next }
    NF > 4 { exit 2 }
    {
      for (column = 1; column <= 4; column++)
        if (invalid($column)) exit 2
      printf "%s%s:%s:%s:%s", (count++ ? "|" : ""), $1, $2, $3, $4
    }
  ' "$credential_arguments_file") || {
    printf 'lmline: credential arguments file has an invalid row: %s\n' \
      "$credential_arguments_file" >&2
    return 1
  }
  # A backslash-newline or backslash-CR-newline outside single quotes is a
  # shell continuation that can split a credential across physical lines.
  # Shield each such continuation with a per-call alphanumeric token before
  # the line rules run, then restore the token to the original bytes. The LF,
  # CR and protection tokens have distinct alphanumeric suffixes, so none is
  # a prefix of another and restoration cannot consume the wrong token.
  # Pre-existing pasted tokens are protected before shields are inserted and
  # restored afterwards, so a pasted shield survives byte-identical.
  # Inside single quotes the backslash is literal, so those lines stay as
  # they are unless the logical line holds a credential prefix (a value
  # split); an even number of trailing backslashes is an escaped backslash.
  cont_token="LMLINECONT${realm_shield_prefix//[^A-Za-z0-9]/}"
  if [[ $cont_token == LMLINECONT ]]; then
    cont_token="LMLINECONT0"
  fi
  cont_token_lf="${cont_token}LF"
  cont_token_cr="${cont_token}CR"
  cont_token_protect="${cont_token}P"
  # The encoded-credential placeholder is unique per clip call, so pasted
  # text cannot impersonate it and suppress later quoted-header rules.
  encoded_mask="LMLINEENCMASK${realm_shield_prefix#@@LMLINE_REALM_SHIELD_}"
  if [[ ! $userinfo_min =~ ^[1-9][0-9]{0,2}$ ]] || (( 10#$userinfo_min > 255 )); then
    userinfo_min=8
  fi
  auth_prefix="([\"']?Authorization[\"']?[[:space:]]*:[[:space:]]*)"
  auth_scheme_name='(Bearer|Basic|Digest|Token|Negotiate|NTLM|OAuth|AWS4-HMAC-SHA256)'
  # An auth-scheme is an RFC 9110 token (tchar), not a URI scheme. '*' stays
  # out of the class so the temporary marker guards remain distinguishable;
  # a single quote is a header delimiter in the rules below.
  auth_scheme_token='[!#$%&+.^_`|~0-9A-Za-z-]'
  # A bare Authorization field follows RFC 9110 tchar, which also allows '*'
  # and "'". Those stay out of the shared class because the quoted-header
  # rules use them as delimiters. Bare fields canonicalize to a custom scheme
  # token so the existing credential rules handle their values and tails.
  # An apostrophe must be followed by another tchar, never end the scheme.
  auth_scheme_bare_noquote="[!#\$%&*+.^_\`|~0-9A-Za-z-]"
  # A scheme with '*' must start with a non-star tchar; a leading '*' is
  # treated as credential data so a star-leading value cannot lose its mask.
  auth_scheme_bare_base="[!#\$%&+.^_\`|~0-9A-Za-z-]"
  auth_scheme_bare="(${auth_scheme_bare_base}+${auth_scheme_bare_noquote}*\\*${auth_scheme_bare_noquote}*|${auth_scheme_bare_base}+('${auth_scheme_bare_noquote}+)+)"
  auth_scheme_bare_canonical=''
  auth_prefix_bare="(^|[^A-Za-z0-9_\"'])(Authorization[[:space:]]*:[[:space:]]*)"
  auth_header_start="(^|[[:space:]();,&|\"'<>])Authorization[[:space:]]*:"
  auth_scheme_any="(${auth_scheme_token}+)"
  auth_scheme="(${auth_scheme_token}+[[:space:]]+)"
  auth_scheme_dq="(\"${auth_scheme_token}+[[:space:]]+)"
  auth_scheme_sq="('${auth_scheme_token}+[[:space:]]+)"
  auth_marker='(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)'
  # Only a canonical already-redacted value is shielded: the marker alone, or
  # one RFC-token scheme followed by separators and the marker. A live
  # credential that ends in a marker spelling is not a redacted value.
  auth_redacted_value="(${auth_scheme_any}([[:space:]]+|[:=]+))?[:=]*[[:space:]]*${auth_marker}"
  key_word='(TOKEN|Token|token|SECRET|Secret|secret|PASSWORD|Password|password|PASS|Pass|pass|KEY|Key|key)'
  key_name="(${key_word}[A-Za-z0-9_-]*|[A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*)"
  key_prefix="((^|[^A-Za-z0-9_/?@#=])([\"']?)${key_name}[\"']?[[:space:]]*[=:][[:space:]]*)"
  # A whole quoted header owns its opening quote in the prefix, so the value
  # ends at that quote rather than at a shell separator.
  key_prefix_quoted_dq="((^|[^A-Za-z0-9_/?@#=])(\")${key_name}[\"']?[[:space:]]*[=:][[:space:]]*)"
  key_prefix_quoted_sq="((^|[^A-Za-z0-9_/?@#=])(')${key_name}[\"']?[[:space:]]*[=:][[:space:]]*)"
  key_prefix_url="(([?&/@#=;,])([\"']?)${key_name}[\"']?[[:space:]]*[=:][[:space:]]*)"
  key_prefix_keep_url="(([?&/@#=;,])\\\\*[\"']?${key_word}[A-Za-z0-9_-]*\\\\*[\"']?[[:space:]]*[=:][[:space:]]*)"
  auth_prefix_escaped_dq="(\\\\*[\"']?Authorization\\\\*[\"']?\\\\*[:][[:space:]]*\\\\*\")"
  auth_prefix_escaped_sq="(\\\\*[\"']?Authorization\\\\*[\"']?\\\\*[:][[:space:]]*\\\\*')"
  auth_scheme_optional="${auth_scheme}?"
  key_prefix_escaped_dq="(\\\\*[\"']?(TOKEN|Token|token|SECRET|Secret|secret|PASSWORD|Password|password|PASS|Pass|pass|KEY|Key|key)[A-Za-z0-9_-]*\\\\*[\"']?\\\\*[:=][[:space:]]*\\\\*\")"
  key_prefix_escaped_sq="(\\\\*[\"']?(TOKEN|Token|token|SECRET|Secret|secret|PASSWORD|Password|password|PASS|Pass|pass|KEY|Key|key)[A-Za-z0-9_-]*\\\\*[\"']?\\\\*[:=][[:space:]]*\\\\*')"
  auth_prefix_quoted_dq="(\"[\"']?Authorization[\"']?[[:space:]]*:[[:space:]]*)"
  auth_prefix_quoted_sq="('[\"']?Authorization[\"']?[[:space:]]*:[[:space:]]*)"
  # Known schemes are shielded so their quoted credentials stay credentials;
  # scheme-less values end at a following quote or shell separator only.
  # Both separator rules emit a marker that starts with a separator and
  # contains @: the @-credential rule cannot match its leading separator and
  # the terminal bare-value rules exclude @, so cleanup still masks a later
  # bare value on the same line.
  # A late cleanup removes an orphaned bare word between a redaction marker
  # and the next quote; a genuine following argument starts with a quote.
  # A shell operator directly after that quote also ends the orphan word.
  # A quoted URL token may hold ; or , only inside plain real quotes with
  # zero backslashes: the separator exception needs a plain quoted URL query
  # (after ?) with [;,][^/...]*= data segments as URL data; with
  # backslash-escaped quotes the quote is literal shell text, so ; and ,
  # are shell separators and no shield applies.
  # The shield is non-empty and stops before ;// or ,// so each authority
  # is handled in turn. Plain-only rules require zero backslashes at both
  # ends and allow [;,] data assignments.
  # URL-embedded Authorization separators are canonicalized before header rules.
  # A chained key may be quoted, as in JSON-shaped transcript text.
  # Single & and | boundaries are kept for recognizable chains; opaque tails fail closed.
  # A keyed value before "; " masks only its value; quoting the temporary
  # marker keeps the terminal bare rule from swallowing the separator.
  # Escaped-key values are masked before their key quotes are canonicalized,
  # so adjacent escaped segments cannot leak.
  # Adjacent escaped segments are consumed as one value.
  # An escaped credential value stops at the next credential key, so that
  # field boundary and its value both survive redaction.
  # Doubled credential-key separators are canonicalized before URL value rules.
  # A canonical already-redacted quoted Authorization value shields its
  # closing quote with a space before both the quoted-argument and terminal
  # rules so neither can eat the next argument or a second live header. The
  # shape is structural, not a marker suffix: live credentials that contain
  # or end with a marker stay live and are masked. The shield is then removed.
  # A generic RFC-token scheme with a separator, blanks and a plain quoted
  # value is masked before the separator is canonicalized; the closing
  # quote bounds the credential, so a following shell word is untouched.
  # A spaced escaped-quote value keeps its quotes and the shell tail; only
  # the credential between them is masked.
  # A generic-scheme value ending at a shell quote keeps that quote: the
  # blank after it starts a new word, so a following argument or header is
  # not part of the credential. Glued quoted pieces have no blank and stay
  # one credential value. A piece must start and end with non-space data:
  # whitespace outside the quotes begins a new shell word, not a credential.
  # An equals-flag whose value starts with a quote may have more glued
  # pieces after that quote; they form one credential up to the shell
  # separator, and the opening quote pair is kept around the marker. A
  # scheme-bearing bare value before a quoted shell word is shielded past
  # the late cleanup so that word is not taken for a scheme-less continuation.
  # The scheme-less rule skips a canonical marker so a second pass is stable.
  # A first URL query parameter named Authorization has no preceding shell
  # separator. Mask padding, a single trailing equals, or a colon-terminated
  # value before quoted-value rules can consume the closing quote and the
  # following shell command. Any character after the closing quote is
  # tolerated, so a glued suffix cannot hide the credential. A realm field
  # is shielded with a per-invocation case-preserving marker because its
  # quoted value is not a secret; only that marker is restored.
  # sshpass takes its password from -p, not from a key=value pair. Mask its
  # own password arguments before the other rules, leaving later command
  # options such as an ssh port untouched.
  # A bare quote after an encoded credential opens another credential segment
  # inside a single-quoted URL: mask each segment up to the closing quote.
  # A closing quote followed by whitespace ends the argument, not a credential. Interior whitespace stays credential data.
  # A percent-encoded = or : after a URL credential key is still a separator;
  # canonicalize it before the URL key rules so the value is masked instead of
  # copied verbatim. Encoded spaces around it are part of the separator form.
  # The value is masked in the same pass, including adjacent escaped segments,
  # so no later quote rule can eat a following shell command.
  # A closing parenthesis or brace ends a grouped command, not a credential:
  # value and tail classes below keep a trailing ) or } for the shell while an
  # internal one followed by credential text stays part of the value.
  # The terminal scheme rule skips canonical markers by their leading * or @
  # so a second pass keeps its closing quote and command group.
  awk -v shield_lf="$cont_token_lf" -v shield_cr="$cont_token_cr" -v raw_token="$cont_token" -v shield_protect="$cont_token_protect" '
    BEGIN {
      sq = sprintf("%c", 39)
      dq = sprintf("%c", 34)
      bs = sprintf("%c", 92)
      cr = sprintf("%c", 13)
      in_s = 0
      in_d = 0
      buf = ""
      has_buf = 0
      buf_shield = ""
      buf_restore = ""
      buf_in_s = 0
      buf_in_d = 0
      buf_has_auth = 0
      buf_has_apikey = 0
      buf_cred = 0
      buf_tail_lc = ""
      buf_trail_has_kw = 0
    }
    # Count trailing backslashes before an optional CR: a CRLF continuation
    # ends with backslash + CR, while the CR is ordinary text on other lines.
    function count_trail(s,    n, i) {
      n = length(s)
      if (n > 0 && substr(s, n, 1) == cr) n--
      i = n
      n = 0
      for (; i >= 1 && substr(s, i, 1) == bs; i--) n++
      return n
    }
    function scan_prefix(s,    i, c, n) {
      n = length(s)
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (in_s) {
          if (c == sq) in_s = 0
          i++
        } else if (in_d) {
          if (c == bs) { i += 2 }
          else if (c == dq) { in_d = 0; i++ }
          else { i++ }
        } else {
          if (c == bs) { if (i < n) i += 2; else i++ }
          else if (c == sq) { in_s = 1; i++ }
          else if (c == dq) { in_d = 1; i++ }
          else { i++ }
        }
      }
    }
    # Incremental quote state for the buffered logical line. The buffer ends
    # with an alphanumeric shield and any kept backslashes are an even run,
    # so both are neutral, but they are scanned to stay exact.
    function scan_buf_seg(s,    i, c, n) {
      n = length(s)
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (buf_in_s) {
          if (c == sq) buf_in_s = 0
          i++
        } else if (buf_in_d) {
          if (c == bs) { i += 2 }
          else if (c == dq) { buf_in_d = 0; i++ }
          else { i++ }
        } else {
          if (c == bs) { if (i < n) i += 2; else i++ }
          else if (c == sq) { buf_in_s = 1; i++ }
          else if (c == dq) { buf_in_d = 1; i++ }
          else { i++ }
        }
      }
    }
    {
      line = $0
      gsub(raw_token, shield_protect, line)
      # A buffered continuation and a new credential on this line are
      # separate credentials, not one split value: emit the buffered line
      # with its backslash preserved instead of swallowing the next line.
      # A split value continues with a bare fragment (no new prefix), while
      # a new header, URL or command starts its own credential. An open
      # single or double quote in the buffered prefix keeps the logical
      # line joined so the closing quote and command tail survive with
      # valid syntax. A buffer that already holds a credential header and
      # a new header on this line are separate credentials even when the
      # buffer ends open. The open test and the header tests use bounded
      # incremental state so each line costs only its own length.
      if (has_buf && (!(buf_in_s || buf_in_d) || buf_has_auth || buf_has_apikey)) {
        ll = tolower(line)
        if (match(ll, /^[[:space:]]*(authorization[[:space:]]*:|.*api-key[[:space:]]*:|url=|curl([[:space:]]|$))/)) {
          prev = substr(buf, 1, length(buf) - length(buf_shield)) buf_restore
          print prev
          buf = ""
          has_buf = 0
          buf_shield = ""
          buf_restore = ""
          buf_in_s = 0
          buf_in_d = 0
          buf_has_auth = 0
          buf_has_apikey = 0
          buf_cred = 0
          buf_tail_lc = ""
          buf_trail_has_kw = 0
        }
      }
      n_bs = count_trail(line)
      odd = (n_bs % 2)
      has_cr = (length(line) > 0 && substr(line, length(line), 1) == cr)
      pre_len = length(line) - n_bs - (has_cr ? 1 : 0)
      prefix = substr(line, 1, pre_len)
      trail = substr(line, pre_len + 1)
      scan_prefix(prefix)
      # Inside single quotes the backslash is literal, except when the
      # logical line already holds a complete header prefix (a value split):
      # then joining lets the line rules mask the whole credential instead
      # of leaking its second half. Prefix splits without a complete prefix
      # stay unjoined to avoid creating a credential from literal text.
      # Work per line is bounded: the global quote scan covers the current
      # prefix only, the credential tests cover the current prefix plus a
      # bounded tail, and the buffered flags are maintained incrementally.
      is_cred = 0
      prefix_lc = ""
      if (odd) {
        prefix_lc = tolower(prefix)
        if (!has_buf) {
          if (match(prefix_lc, /authorization[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /api[-_]key[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /(^|[^a-z0-9])(-u|--u|--user)[[:space:]=]/)) is_cred = 1
          else if (match(prefix_lc, /--password([[:space:]]|=)/)) is_cred = 1
          else if (match(prefix_lc, /[a-z0-9_.-]*(token|secret|password|pass|key)[a-z0-9_-]*[[:space:]]*[=:]/)) is_cred = 1
        } else if (buf_cred) {
          is_cred = 1
        } else {
          if (match(prefix_lc, /authorization[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /api[-_]key[[:space:]]*:/)) is_cred = 1
          else if (match(prefix_lc, /[^a-z0-9](-u|--u|--user)[[:space:]=]/)) is_cred = 1
          else if (match(prefix_lc, /--password([[:space:]]|=)/)) is_cred = 1
          else if (match(prefix_lc, /[a-z0-9_.-]*(token|secret|password|pass|key)[a-z0-9_-]*[[:space:]]*[=:]/)) is_cred = 1
          else if (buf_trail_has_kw && match(prefix_lc, /^[a-z0-9_-]*[[:space:]]*[=:]/)) is_cred = 1
        }
      }
      if (odd && (!in_s || is_cred)) {
        keep = (n_bs > 1) ? substr(trail, 1, n_bs - 1) : ""
        buf_shield = has_cr ? shield_cr : shield_lf
        buf_restore = has_cr ? bs cr : bs
        scan_buf_seg(prefix)
        if (keep != "") scan_buf_seg(keep)
        scan_buf_seg(buf_shield)
        if (prefix_lc == "") prefix_lc = tolower(prefix)
        p_auth = match(prefix_lc, /authorization[[:space:]]*:/)
        p_apikey = match(prefix_lc, /api[-_]key[[:space:]]*:/)
        old_tail = buf_tail_lc
        old_has_kw = buf_trail_has_kw
        shield_lc = tolower(buf_shield)
        seg_lc = prefix_lc keep shield_lc
        tmp_tail = old_tail seg_lc
        if (length(tmp_tail) > 128) buf_tail_lc = substr(tmp_tail, length(tmp_tail) - 127)
        else buf_tail_lc = tmp_tail
        seg_len = length(seg_lc)
        last_break = 0
        for (k = seg_len; k >= 1; k--) {
          cc = substr(seg_lc, k, 1)
          if (!((cc >= "a" && cc <= "z") || (cc >= "0" && cc <= "9") || cc == "_" || cc == "-")) {
            last_break = k
            break
          }
        }
        if (last_break > 0) {
          suffix = substr(seg_lc, last_break + 1)
          buf_trail_has_kw = match(suffix, /(token|secret|password|pass|key)/) ? 1 : 0
        } else {
          if (old_has_kw) buf_trail_has_kw = 1
          else {
            if (length(old_tail) >= 7) old_suffix = substr(old_tail, length(old_tail) - 6)
            else old_suffix = old_tail
            buf_trail_has_kw = match(old_suffix seg_lc, /(token|secret|password|pass|key)/) ? 1 : 0
          }
        }
        buf_has_auth = (buf_has_auth || p_auth) ? 1 : 0
        buf_has_apikey = (buf_has_apikey || p_apikey) ? 1 : 0
        buf_cred = is_cred ? 1 : 0
        if (has_buf) buf = buf prefix keep buf_shield
        else { buf = prefix keep buf_shield; has_buf = 1 }
        next
      } else {
        if (has_buf) { print buf line; buf = ""; has_buf = 0; buf_in_s = 0; buf_in_d = 0; buf_has_auth = 0; buf_has_apikey = 0; buf_cred = 0; buf_tail_lc = ""; buf_trail_has_kw = 0 }
        else print line
      }
    }
    END {
      if (has_buf) {
        buf = substr(buf, 1, length(buf) - length(buf_shield)) buf_restore
        print buf
      }
    }
  ' | awk -v credential_spec="$credential_arguments_spec" '
    function is_sep(c) {
      return c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">"
    }
    function redact_value(v) {
      if (substr(v, 1, 2) == "$" sq && substr(v, length(v), 1) == sq)
        return "$" sq "***REDACTED***" sq
      if (substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"")
        return "\"***REDACTED***\""
      if (substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq)
        return sq "***REDACTED***" sq
      return "***REDACTED***"
    }
    function parse_word(s, i,    c, out, n, q) {
      out = ""
      n = length(s)
      while (i <= n) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]]/ || is_sep(c)) break
        if ((c == "\"" || c == sq || (c == "$" && substr(s, i + 1, 1) == sq)) &&
            (out == "" || (i < n && substr(s, i + 1, 1) !~ /[[:space:]]/ && !is_sep(substr(s, i + 1, 1))))) {
          q = c
          if (q == "$") { out = out "$"; i++; q = sq }
          out = out q; i++
          while (i <= n) {
            c = substr(s, i, 1)
            out = out c; i++
            if (c == "\\" && i <= n) { out = out substr(s, i, 1); i++; continue }
            if (c == q) break
          }
          continue
        }
        if (c == "\"" || c == sq || (c == "$" && substr(s, i + 1, 1) == sq)) break
        out = out c; i++
      }
      word_text = out
      word_end = i
    }
    BEGIN {
      sq = sprintf("%c", 39)
      no_value = ",v,e,T,h,"
      rule_count = 0
      rows = split(credential_spec, rule_rows, "[|]")
      for (r = 1; r <= rows; r++) {
        if (rule_rows[r] == "") continue
        fields = split(rule_rows[r], cols, ":")
        for (pad = fields + 1; pad <= 4; pad++) cols[pad] = ""
        rule_count++
        rule_cmd[rule_count] = tolower(cols[1])
        rule_cred[rule_count] = "," cols[2] ","
        rule_keep[rule_count] = "," cols[3] ","
        rule_pos[rule_count] = "," tolower(cols[4]) ","
        cred_n[rule_count] = split(cols[2], tmp_flags, ",")
        for (j = 1; j <= cred_n[rule_count]; j++) cred_f[rule_count, j] = tmp_flags[j]
        keep_n[rule_count] = split(cols[3], tmp_flags, ",")
        for (j = 1; j <= keep_n[rule_count]; j++) keep_f[rule_count, j] = tmp_flags[j]
      }
    }
    function has_flag(list, flag) {
      return index(list, "," flag ",") > 0
    }
    # A command phrase in the policy marks a boundary: process() can re-enter
    # with the rule for that command instead of applying the outer rule further.
    function command_at(pos,    ci, clen, best, before, after) {
      best = 0
      for (ci = 1; ci <= rule_count; ci++) {
        clen = length(rule_cmd[ci])
        if (clen <= best || substr(line_low, pos, clen) != rule_cmd[ci]) continue
        before = pos > 1 ? substr(line_text, pos - 1, 1) : ""
        after = substr(line_text, pos + clen, 1)
        if ((pos == 1 || is_before(before) || before == sq) &&
            (after == "" || is_after(after) || after == sq)) best = clen
      }
      return best
    }
    function match_long(name,    j, f, best) {
      matched_flag = ""; matched_kind = ""; best = 0
      for (j = 1; j <= cred_n[cur_rule]; j++) {
        f = cred_f[cur_rule, j]
        if (f != "" && tolower(f) == tolower(name) && length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "cred"
        }
      }
      for (j = 1; j <= keep_n[cur_rule]; j++) {
        f = keep_f[cur_rule, j]
        if (f != "" && tolower(f) == tolower(name) && length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "keep"
        }
      }
    }
    # Short flags are case-sensitive; longer names match case-insensitively.
    # The longest policy flag wins, so -passin is not split into -pass plus data.
    function match_at(name, from,    j, f, cand, best) {
      matched_flag = ""; matched_kind = ""; best = 0
      for (j = 1; j <= cred_n[cur_rule]; j++) {
        f = cred_f[cur_rule, j]
        cand = substr(name, from, length(f))
        if (f != "" && ((length(f) == 1 && cand == f) ||
                        (length(f) > 1 && tolower(cand) == tolower(f))) &&
            length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "cred"
        }
      }
      for (j = 1; j <= keep_n[cur_rule]; j++) {
        f = keep_f[cur_rule, j]
        cand = substr(name, from, length(f))
        if (f != "" && ((length(f) == 1 && cand == f) ||
                        (length(f) > 1 && tolower(cand) == tolower(f))) &&
            length(f) > best) {
          best = length(f); matched_flag = f; matched_kind = "keep"
        }
      }
    }
    # Consume one following word, keeping whitespace and separators byte-exact.
    # A preserved flag does not swallow the next flag as its value.
    function append_value(mask, from,    j) {
      value_out = ""; value_end = from
      j = from
      while (j <= scan_n && substr(scan_s, j, 1) ~ /[[:space:]]/) {
        value_out = value_out substr(scan_s, j, 1); j++
      }
      if (j <= scan_n && !is_sep(substr(scan_s, j, 1)) &&
          (mask || substr(scan_s, j, 1) != "-")) {
        parse_word(scan_s, j)
        value_out = value_out (mask ? redact_value(word_text) : word_text)
        value_end = word_end
      } else {
        value_end = j
      }
    }
    function scan(s, start,    i, c, out, w, k, name, eq, attached, has_eq, stub, j, pending, rest, tail, clen) {
      scan_s = s; scan_n = length(s)
      out = ""; i = start; scan_end = scan_n + 1
      while (i <= scan_n) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]]/) { out = out c; i++; continue }
        if (i > start && command_at(i) > 0) { scan_end = i; return out }
        if (is_sep(c)) { out = out c; scan_end = i + 1; return out }
        parse_word(s, i)
        w = word_text; k = word_end
        # A quoted word can contain a whole command line; stop inside it so
        # process() can match the nested command with its own policy row.
        for (j = i + 1; j < k; j++) {
          if (command_at(j) > 0) {
            out = out substr(s, i, j - i); scan_end = j; return out
          }
        }
        if (w == "--help" || w == "--version") { out = out w; i = k; continue }
        # Bare operands (a registry, a key name, a filename) are copied, not
        # treated as the end of the command. Later arguments still get scanned.
        if (substr(w, 1, 1) != "-" && has_flag(rule_pos[cur_rule], tolower(w))) {
          append_value(1, k)
          out = out w value_out
          i = value_end
          continue
        }
        if (substr(w, 1, 2) == "--") {
          name = substr(w, 3)
          eq = index(name, "=")
          if (eq > 0) {
            attached = substr(name, eq + 1); name = substr(name, 1, eq - 1); has_eq = 1
          } else {
            attached = ""; has_eq = 0
          }
          match_long(name)
          if (matched_flag != "") {
            stub = "--" name (has_eq ? "=" : "")
            if (attached != "") {
              out = out stub (matched_kind == "cred" ? redact_value(attached) : attached)
                            i = k
              continue
            }
            append_value(matched_kind == "cred", k)
            out = out stub value_out
                        i = value_end
            continue
          }
          out = out w; i = k; continue
        }
        if (substr(w, 1, 1) == "-" && length(w) > 1) {
          name = substr(w, 2)
          eq = index(name, "=")
          if (eq > 0) { tail = substr(name, eq + 1); name = substr(name, 1, eq - 1) }
          else tail = ""
          j = 1; pending = 1
          while (j <= length(name)) {
            match_at(name, j)
            if (matched_flag != "") {
              out = out "-" substr(name, pending, j - pending) substr(name, j, length(matched_flag))
              pending = j + length(matched_flag)
              rest = substr(name, pending)
              if (rest != "" || tail != "") {
                out = out (rest != "" ? "" : "=") \
                  (matched_kind == "cred" ? redact_value(rest tail) : rest tail)
                                i = k
                break
              }
              append_value(matched_kind == "cred", k)
              out = out value_out
                            i = value_end
              break
            }
            if (has_flag(no_value, substr(name, j, 1))) { j++; continue }
            out = out "-" substr(name, pending)
            if (tail != "") out = out "=" tail
            i = k
            break
          }
          if (j > length(name)) { out = out "-" substr(name, pending); i = k }
          continue
        }
        out = out w; i = k
      }
      return out
    }
    function is_before(c) {
      return (c ~ /[[:space:]]/ || c == ";" || c == "," || c == "&" || c == "|" ||
              c == "(" || c == "/" || c == "=" || c == "\"")
    }
    function is_after(c) {
      return (c ~ /[[:space:]]/ || c == ";" || c == "," || c == "&" || c == "|" ||
              c == ")" || c == "/" || c == "=" || c == "\"")
    }
    # Match whole command phrases, longest first, then scan only their tail.
    function process(s,    out, low, n, i, ci, clen, best, best_rule, before, after, seg) {
      out = ""
      line_text = s; line_low = tolower(s)
      low = line_low
      n = length(s)
      i = 1
      while (i <= n) {
        best = 0; best_rule = 0
        for (ci = 1; ci <= rule_count; ci++) {
          clen = length(rule_cmd[ci])
          if (clen <= best || substr(low, i, clen) != rule_cmd[ci]) continue
          before = i > 1 ? substr(s, i - 1, 1) : ""
          after = substr(s, i + clen, 1)
          if ((i == 1 || is_before(before) || before == sq) &&
              (after == "" || is_after(after) || after == sq)) {
            best = clen; best_rule = ci
          }
        }
        if (best == 0) { out = out substr(s, i, 1); i++; continue }
        out = out substr(s, i, best)
        cur_rule = best_rule
        seg = scan(s, i + best)
        out = out seg
        i = scan_end
      }
      return out
    }
    { print process($0) }
  ' | sed -E \
    -e "s/${auth_prefix_bare}${auth_scheme_bare}([[:space:]]*[:=]+[[:space:]]*|[[:space:]]+)[\"'](([^\"\\\\]|\\\\.)*)[\"']/\\1\\2@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix_bare}${auth_scheme_bare}([[:space:]]*[:=]+[[:space:]]*|[[:space:]]+)'(([^'\\\\]|\\\\.)*)'/\\1\\2@@LMLINE_REDACTED@@/Ig" \
    -e "/${auth_prefix_bare}${auth_scheme_bare}([[:space:]]+|[:=]+)[[:space:]]*${auth_marker}/!s/${auth_prefix_bare}${auth_scheme_bare}([[:space:]]+|[:=]+)/\\1\\2${auth_scheme_bare_canonical}:/Ig" \
    -e "s/${auth_header_start}[[:space:]:=]*[:=][[:space:]:=]*([^[:space:]\"';,|&<>]+)/\\1Authorization: ***REDACTED***/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([[:space:]]+|[^[:space:]\"':;,|&<>/]+[[:space:]]+)[^[:space:]\"':;,|&<>/]+:[^[:space:]\"';,&|<>/]+/\1\2***REDACTED***/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=]+[[:space:]]*)(realm)=/\1\2\3${realm_shield_prefix}\4@@/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,\"']+[^[:space:]&;,\"']*=)((\\\\?[\"'])|[[:space:];,&<>|]|$)/\1\2:***REDACTED***\6/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*={2,}|[^[:space:]&;,=\"']*:+|([A-Za-z0-9+/]{4})*[A-Za-z0-9+/]{3}=)((\\\\?[\"'])|[[:space:];,&<>|]|$)/\1\2:***REDACTED***\7/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=]+[[:space:]]*)${realm_shield_prefix}([A-Za-z]+)@@/\1\2\3\4=/Ig" \
    -e "s/(^|[^[:alnum:]_-])(-u)([^[:space:]\"':;,|&<>=]+):([^[:space:]\"';,&|<>\\\\]|\\\\.)*([^[:space:]\"';,&|<>)}\\\\]|\\\\.)(((\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*')([^][:space:];,&|<>\"')}]*))*)/\\1\\2\\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^[:alnum:]_-])(-u)([^[:space:]\"':;,|&<>=]+):(((\"([^\"\\\\]|\\\\.)*\"|'([^'\\\\]|\\\\.)*')([^][:space:];,&|<>\"')}]*))+)/\\1\\2\\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^[:alnum:]_-])(-u)([\"'])([^\"':]+):([^\"']+)([\"'])/\\1\\2\\3\\4:@@LMLINE_REDACTED@@\\6/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([^[:space:]\"':;,|&]+):([^[:space:]\"';,&|<>\\\\]|\\\\.)*([^[:space:]\"';,&|<>)}\\\\]|\\\\.)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=)([^[:space:]\"':;,|&<>\\\\]|\\\\.)*([^[:space:]\"':;,|&<>)}\\\\]|\\\\.)([[:space:];,&|<>{)}]|$)/\1\2@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/(^|[[:space:]])(--user=)([0-9]*(\\\\[^\"']|[^0-9[:space:]\"':;,|&<>])([^[:space:]\"':;,|&<>\\\\]|\\\\.)*([^[:space:]\"':;,|&<>)}\\\\]|\\\\.))([[:space:];,&|<>{)}]|$)/\1\2@@LMLINE_REDACTED@@\7/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([^[:space:]\"';,|&<>\\\\]|\\\\.)+(\"([^\"\\\\]|\\\\.)*\"([^][:space:];,&|<>\"')} ]|\\\\.)*)+([[:space:];,&|<>{)}]|$)/\1\2@@LMLINE_REDACTED@@\7/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([^[:space:]\"';,|&<>\\\\]|\\\\.)+('([^'\\\\]|\\\\.)*'([^][:space:];,&|<>\"')} ]|\\\\.)*)+([[:space:];,&|<>{)}]|$)/\1\2@@LMLINE_REDACTED@@\7/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([\"'])([^[:space:]\"':]+):([^\"']+)([\"'])/\1\2\3\4:@@LMLINE_REDACTED@@\6/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)(\")([^\"\\\\]|\\\\.)*\"([^[:space:];,&|<>{)}]+)([[:space:];,&|<>{)}]|$)/\1\2\3@@LMLINE_REDACTED@@\3\6/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)(')([^'\\\\]|\\\\.)*'([^[:space:];,&|<>{)}]+)([[:space:];,&|<>{)}]|$)/\1\2\3@@LMLINE_REDACTED@@\3\6/Ig" \
    -e "/@@LMLINE_REDACTED@@/!s/(^|[[:space:]])(-u=|--u=|--user=)([\"'])([^\"']+)([\"'])/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)(\\\\*)\"([^[:space:]\"':]+):([^\"\\\\']*)(\\\\*)\"/\1\2\3\"\4:@@LMLINE_REDACTED@@\6\"/Ig" \
    -e "/@@LMLINE_REDACTED@@/!s/(^|[[:space:]])(-u=|--u=|--user=)(\\\\*)\"([^\"\\\\']*)(\\\\*)\"/\1\2\3\"@@LMLINE_REDACTED@@\5\"/Ig" \
    -e "s/(^|[[:space:]])(-u[[:space:]]+|--u[[:space:]]+|--user[[:space:]]+)([^[:space:]\"':;,|&]+):([^[:space:]\"';,&|<>\\\\]|\\\\.)*([^[:space:]\"';,&|<>)}\\\\]|\\\\.)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[[:space:]])(-u[[:space:]]+|--u[[:space:]]+|--user[[:space:]]+)([\"'])([^[:space:]\"':]+):([^\"']+)([\"'])/\1\2\3\4:@@LMLINE_REDACTED@@\6/Ig" \
    -e "s/(^|[[:space:]])(--password[[:space:]]+)(([^[:space:]\"';,&|<>\\\\]|\\\\.)+)/\1\2@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[[:space:]])(--password[[:space:]]+)(\")([^\"']+)([\"])/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/(^|[[:space:]])(--password[[:space:]]+)(')([^']+)(')/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/(^|[[:space:];,&|(/=])(mysql|mysqldump|mysqladmin|mysqlshow|mariadb|mariadb-dump|mariadb-admin)([[:space:];,&|)/=]|$)/\1\2@@LMLINE_DBCMD@@\3/Ig" \
    -e "s/(@@LMLINE_DBCMD@@[^;&|]*)([[:space:]])(-p)(([^[:space:]\"\');,&|<>\\\\]|\\\\.)+)/\1\2\3@@LMLINE_REDACTED@@/g" \
    -e "s/(@@LMLINE_DBCMD@@[^;&|]*)(-p)([\"\'])([^\"\']+)([\"\'])/\1\2\3@@LMLINE_REDACTED@@\5/g" \
    -e 's#(([A-Za-z][A-Za-z0-9+.-]*:)//[^:/?#@[:space:]]*:)[^/?#@[:space:]]+@#\1@@LMLINE_REDACTED@@@#g' \
    -e 's#(://[;,]//[^/?#@[:space:]]*:)[^/?#@[:space:]]+@#\1@@LMLINE_REDACTED@@@#g' \
    -e ':lmline_quote_sep_protect' \
    -e 's%(^|[[:space:]=:,({;|&#)])"(([^"\\]|\\.)*[A-Za-z][A-Za-z0-9+.-]*://([^[:space:]|&#)\\";,]+|[^[:space:]|&#)\\";,?]*[?]([^[:space:]|&#)\\";,]|[;,][^/[:space:]\\"]*=)+));//(([^\\"\\]|\\.)*)"%\1"\2@@LMLINE_QUOTED_SEMI@@\6"%g' \
    -e 's%(^|[[:space:]=:,({;|&#)])"(([^"\\]|\\.)*[A-Za-z][A-Za-z0-9+.-]*://([^[:space:]|&#)\\";,]+|[^[:space:]|&#)\\";,?]*[?]([^[:space:]|&#)\\";,]|[;,][^/[:space:]\\"]*=)+)),//(([^\\"\\]|\\.)*)"%\1"\2@@LMLINE_QUOTED_COMMA@@\6"%g' \
    -e "s%(^|[[:space:]=:,({;|&#)])'([^']*[A-Za-z][A-Za-z0-9+.-]*://([^[:space:]|&#)\\\",;']+|[^[:space:]|&#)\\\",;'?]*[?]([^[:space:]|&#)\\\",;']|[;,][^/[:space:]\\\"']*=)+));//([^']*)'%\\1'\\2@@LMLINE_QUOTED_SEMI@@\\5'%g" \
    -e "s%(^|[[:space:]=:,({;|&#)])'([^']*[A-Za-z][A-Za-z0-9+.-]*://([^[:space:]|&#)\\\",;']+|[^[:space:]|&#)\\\",;'?]*[?]([^[:space:]|&#)\\\",;']|[;,][^/[:space:]\\\"']*=)+)),//([^']*)'%\\1'\\2@@LMLINE_QUOTED_COMMA@@\\5'%g" \
    -e 't lmline_quote_sep_protect' \
    -e 'h' \
    -e ':lmline_url_sep_norm1' \
    -e "s/(^|[^\\\\])'[^']*'|(^|[^\\\\])\"([^\"\\\\]|\\\\.)*\"/\\1/g" \
    -e 't lmline_url_sep_norm1' \
    -e "s#(^|.)([;,])//([^:/?#@[:space:]]*:)[^/?#@[:space:]]+@#\\1\\2//\\3@@LMLINE_REDACTED@@@#g" \
    -e 't lmline_url_sep_apply1' \
    -e 'x' \
    -e 'b lmline_url_sep_done1' \
    -e ':lmline_url_sep_apply1' \
    -e 'x' \
    -e "s#(^|.)([;,])//([^:/?#@[:space:]]*:)[^/?#@[:space:]]+@#\\1\\2//\\3@@LMLINE_REDACTED@@@#g" \
    -e ':lmline_url_sep_done1' \
    -e 'h' \
    -e ':lmline_url_sep_norm2' \
    -e "s/(^|[^\\\\])'[^']*'|(^|[^\\\\])\"([^\"\\\\]|\\\\.)*\"/\\1/g" \
    -e 't lmline_url_sep_norm2' \
    -e "s#(^|.)([;,])//([^:/?#@[:space:]]{${userinfo_min},})@#\\1\\2//@@LMLINE_REDACTED@@@#g" \
    -e 't lmline_url_sep_apply2' \
    -e 'x' \
    -e 'b lmline_url_sep_done2' \
    -e ':lmline_url_sep_apply2' \
    -e 'x' \
    -e "s#(^|.)([;,])//([^:/?#@[:space:]]{${userinfo_min},})@#\\1\\2//@@LMLINE_REDACTED@@@#g" \
    -e ':lmline_url_sep_done2' \
    -e 's#(^|[^A-Za-z0-9_./?@#&=:;,-])(//[^:/?#@[:space:]]*:)[^/?#@[:space:]]+@#\1\2@@LMLINE_REDACTED@@@#g' \
    -e 's#(^|[^A-Za-z0-9_/?@#&=:])([[:alnum:]_][[:alnum:]0-9_-]*=)(//[^:/?#@[:space:]]*:)[^/?#@[:space:]]+@#\1\2\3@@LMLINE_REDACTED@@@#g' \
    -e "s#(([A-Za-z][A-Za-z0-9+.-]*:)//)[^:/?#@[:space:]]{${userinfo_min},}@#\1@@LMLINE_REDACTED@@@#g" \
    -e "s#(^|[^A-Za-z0-9_./?@#&=:;,-])(//)[^:/?#@[:space:]]{${userinfo_min},}@#\1\2@@LMLINE_REDACTED@@@#g" \
    -e "s#(^|[^A-Za-z0-9_/?@#&=:])([[:alnum:]_][[:alnum:]0-9_-]*=)(//)[^:/?#@[:space:]]{${userinfo_min},}@#\1\2\3@@LMLINE_REDACTED@@@#g" \
    -e "s/([?&/@#=;,])\\\\\"Authorization\\\\\"((%20)*)%3[DdAa]((%20)*)(([^&;,|<>\\\"'\\\\]|\\\\[^&;,|<>])|([']*([^]})\$[:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])|[\"]*([^]})\$[:alnum:][:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])))*\\\\?/\1Authorization:${encoded_mask}/Ig" \
    -e "s/([?&/@#=;,])\\\'Authorization\\\'((%20)*)%3[DdAa]((%20)*)(([^&;,|<>\\\"'\\\\]|\\\\[^&;,|<>])|([']*([^]})\$[:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])|[\"]*([^]})\$[:alnum:][:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])))*\\\\?/\1'Authorization':${encoded_mask}/Ig" \
    -e "s/([?&/@#=;,])([\"']?Authorization[\"']?)((%20)*)(%3[DdAa])((%20)*)(([^&;,|<>\\\"'\\\\]|\\\\[^&;,|<>])|([']*([^]})\$[:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])|[\"]*([^]})\$[:alnum:][:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])))*\\\\?/\1\2:${encoded_mask}/Ig" \
    -e "s/([?/@#=])(\"[']?)?(Authorization)(\"[']?)?([[:space:]]*)[:=]([[:space:]]*)([:=])?([[:space:]]*)/\1\2\3\4:\8/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([[:space:]])/\\1==LMLINE_AUTH_SCHEME==\\2\\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)[[:space:]]+/\1\2\3/Ig" \
    -e "/[?/@#=]Authorization:/!s/${auth_prefix}${auth_scheme_any}([:=]+)\"(([^\"\\\\]|\\\\.)*)\"/\1\2\3\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "/[?/@#=]Authorization:/!s/${auth_prefix}${auth_scheme_any}([:=]+)'(([^'\\\\]|\\\\.)*)'/\1\2\3'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+\"(([^\"\\\\]|\\\\.)*)\"/\1\2\3\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+'(([^'\\\\]|\\\\.)*)'/\1\2\3'@@LMLINE_REDACTED@@'/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+([^\\\"='[:space:];,&|]+)(\")([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+([^\\\"='[:space:];,&|]+)(')([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+/\1\2\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:]+)([^\\\"'[:space:];,&|<>]*)([\"'])$/\1\2\3***REDACTED***\5/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"'[:space:];,&|]+)([[:space:]]+)/\1***REDACTED***\5/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"='[:space:];,&|]+)(\")([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"='[:space:];,&|]+)(')([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)\"(([^\"\\\\]|\\\\.)*)\"/\\1\\2\\3\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)'(([^'\\\\]|\\\\.)*)'/\\1\\2\\3'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)\"(([^\"\\\\]|\\\\([^\"]))*)(\\\\+)\"/\1\2\3\4\"@@LMLINE_REDACTED@@\8\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)'(([^'\\\\]|\\\\([^']))*)(\\\\+)'/\1\2\3\4'@@LMLINE_REDACTED@@\8'/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)\"(([^\"\\\\]|\\\\([^\"]))*)\$/\1\2\3\4\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)\"(([^\"\\\\]|\\\\([^\"]))*\\\\)\$/\1\2\3\4\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)'(([^'\\\\]|\\\\([^']))*)\$/\1\2\3\4'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)'(([^'\\\\]|\\\\([^']))*\\\\)\$/\1\2\3\4'@@LMLINE_REDACTED@@/Ig" \
    -e ':lmline_auth_scheme_seg_loop' \
    -e "s/(@@LMLINE_REDACTED@@(\\\\*[\"']|[\"']))(((\\\\*[\"']|[\"']))([^[:space:]\"']([^\"']*[^[:space:]\"'])?)?(\\\\*[\"']|[\"']))+/\1/Ig" \
    -e 't lmline_auth_scheme_seg_loop' \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)\"(([^\"\\\\]|\\\\.)*)$/\\1\\2\\3\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)\"(([^\"\\\\]|\\\\.)*\\\\)$/\\1\\2\\3\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)'(([^'\\\\]|\\\\.)*)$/\\1\\2\\3'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)'(([^'\\\\]|\\\\.)*\\\\)$/\\1\\2\\3'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\"'=[:space:];,&|][^\"'[:space:];,&|]*)([[:space:]]+)([\"'])/\\1==LMLINE_AUTH_VALUE==\\5\\6/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)/!s/${auth_prefix}(\*[^[:space:]\"'=;,|&<>]+)([[:space:]]+)([\"'])/\\1==LMLINE_AUTH_VALUE==\\3\\4/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)/!s/${auth_prefix}([^\"'=[:space:];,&|][^\"'[:space:];,&|]*)([[:space:]]+)([\"'])/\\1@@LMLINE_REDACTED@@\\3\\4/Ig" \
    -e "s/${auth_prefix}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]*([>][>]|[<][<]|[|][|]|&&|[,;|&<>]))/\\1;@LMLINE_SEP@\\3/Ig" \
    -e "s/${auth_prefix}==LMLINE_AUTH_SCHEME==${auth_scheme}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]*)([>][>]|[<][<]|[|][|]|&&|[,;|&<>])/\1==LMLINE_AUTH_SCHEME==\2;@LMLINE_SEP@\4\5/Ig" \
    -e "s/${auth_prefix}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]+[0-9]+[[:space:]]*([>][>]|[<][<]|[<>]))/\\1;@LMLINE_SEP@\\3/Ig" \
    -e "s/${auth_prefix}==LMLINE_AUTH_SCHEME==${auth_scheme}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]+[0-9]+[[:space:]]*)([>][>]|[<][<]|[<>])/\1==LMLINE_AUTH_SCHEME==\2;@LMLINE_SEP@\4\5/Ig" \
    -e 's/==LMLINE_AUTH_SCHEME==//Ig' \
    -e 's/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]*'"${auth_redacted_value}"')\"/\1 \"/Ig' \
    -e "s/('[^']*Authorization[[:space:]]*:[[:space:]]*${auth_redacted_value})'/\1 '/Ig" \
    -e "s/(^|[^A-Za-z0-9_])([[:space:]]*)${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\\\"'=[:space:];,&|][^\\\"'[:space:];,&|]*)((\"((([^[:space:]\"])([^\"]*[^[:space:]\"]))|([^[:space:]\"]))?\"|'((([^[:space:]'])([^']*[^[:space:]']))|([^[:space:]']))?'))([^[:space:]\"';,&|]*)/\1\2\3\4\5@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^A-Za-z0-9_])([[:space:]]*)${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\\\\\"'=[:space:];,&|][^\\\\\"'[:space:];,&|]*)(\\\\+[\"])(([^[:space:];,&|\"'])*(\\\\+[\"']([^[:space:];,&|\"'])*)*)/\1\2\3\4\5@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^A-Za-z0-9_])([[:space:]]*)${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\\\\\"'=[:space:];,&|][^\\\\\"'[:space:];,&|]*)(\\\\+['])(([^[:space:];,&|\"'])*(\\\\+[\"']([^[:space:];,&|\"'])*)*)/\1\2\3\4\5@@LMLINE_REDACTED@@/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"\"([^\"]*\\\\\"[^\"]*)\"[^[:space:]]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/('[^']*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'(\"([^\"]*\\\\\"[^\"]*)\"|'[^']*\\\\.[^']*')[^[:space:]]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1\2@@LMLINE_REDACTED@@\"/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/('[^']*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1\2@@LMLINE_REDACTED@@'/Ig" \
    -e ':auth_adjacent_loop' \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/((\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@\")(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/(('[^']*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@')(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1/Ig" \
    -e 't auth_adjacent_loop' \
    -e "s/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"([0-9]+)([><])/\\1\\2@@LMLINE_REDACTED@@\\\"\\4\\5/Ig" \
    -e "s/('[^']*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'([0-9]+)([><])/\\1\\2@@LMLINE_REDACTED@@'\\4\\5/Ig" \
    -e 's/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]*'"${auth_redacted_value}"')\"/\1 \"/Ig' \
    -e "s/('[^']*Authorization[[:space:]]*:[[:space:]]*${auth_redacted_value})'/\1 '/Ig" \
    -e "s/(\"[^\";,&|<>]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"[^[:space:]';,&:<>)}]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
    -e "s/(\"[^\"[:space:];,&|]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"[^[:space:]';,&:<>)}]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
    -e "s/('[^';,&|<>]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'[^[:space:]';,&:<>)}]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
    -e "s/('[^'[:space:];,&|]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'[^[:space:]';,&:<>)}]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
    -e 's/("[^"]*Authorization:[^"]*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)) "/\1"/Ig' \
    -e "s/('[^']*Authorization:[^']*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)) '/\1'/Ig" \
    -e "s/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@\\\"/\\1\\2##LMLINE_REDACTED##\\\"/Ig" \
    -e "s/('[^']*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@'/\\1\\2##LMLINE_REDACTED##'/Ig" \
    -e "s/([?&/@#=;,])(((\\\\?\")?[A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*(\\\\?\")?)|(\\\\'[A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*\\\\')|('[A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*'))((%20)*)(%3[DdAa])((%20)*)(([^&;,|<>\\\"'\\\\]|\\\\[^&;,|<>])|([']*([^]})\$[:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])|[\"]*([^]})\$[:alnum:][:space:]&;,|<>\\\"'\\\\]|\\\\[^[:space:]&;,|<>])))*\\\\?/\1\2=${encoded_mask}/Ig" \
    -e "s/(${encoded_mask}[\\\"])([^[:space:]&;,|<>\\\"'\\\\][^&;,|<>\\\"'\\\\]*)(&)/\1${encoded_mask}\3/g" \
    -e "s/(${encoded_mask}\")([^[:space:]&;,|<>\\\\'][^&;,|<>\\\\']*)(\")([^[:space:]&;,|<>\\\\'][^&;,|<>\\\\']*)([\"'])/\1${encoded_mask}\3${encoded_mask}\5/g" \
    -e "s/(${encoded_mask}\")([^[:space:]&;,|<>\\\\\"'\\\\][^&;,|<>\\\\\"'\\\\]*)([\"'])/\1${encoded_mask}\3/g" \
    -e "s/([?&/@#=;,])([A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*)([[:space:]]*)([:=])([[:space:]]*)([:=])([[:space:]]*)/\1\2\4\5\8/Ig" \
    -e "s/${key_prefix_url}\"(([^\"\\\\]|\\\\.)*)\"/\1\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${key_prefix_url}'(([^'\\\\]|\\\\.)*)'/\1'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${key_prefix_keep_url}(\\\\+)\"([^\"\\\\]|\\\\.)*(\\\\+)\"([;,|&])([A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*[[:space:]]*[:=][[:space:]]*)/\1\"@@LMLINE_REDACTED@@\"\7\8/Ig" \
    -e "s/(${key_prefix_url})(\\\\+[\"']|[\"'])(\\\\+[\"']|[\"'])[^&,;|]*/\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix_keep_url}(\\\\+)'([^\'\\\\]|\\\\.)*(\\\\+)'([;,|&])([A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*[[:space:]]*[:=][[:space:]]*)/\1'@@LMLINE_REDACTED@@'\7\8/Ig" \
    -e "s/${key_prefix_url}((\\\\+)\"([^\"\\\\]|\\\\.)*(\\\\+)\")+/\1\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${key_prefix_url}((\\\\+)'([^'\\\\]|\\\\.)*(\\\\+)')+/\1'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix_escaped_dq}${auth_scheme_optional}(([^\"\\\\]|\\\\.)*)(\\\\*\")([[:space:]]*[]},])/\1\2@@LMLINE_REDACTED@@\5\6/Ig"\
    -e "s/${auth_prefix_escaped_dq}${auth_scheme_optional}(([^\"\\\\]|\\\\.)*\\\\?)(\"?)$/\1\2@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/${key_prefix_escaped_dq}(([^\"\\\\]|\\\\.)*)(\\\\*\")([[:space:]]*[]},])/\1@@LMLINE_REDACTED@@\5\6/Ig"\
    -e "s/${key_prefix_escaped_dq}(([^\"\\\\]|\\\\.)*\\\\?)(\"?)$/\1@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/${auth_prefix_escaped_sq}${auth_scheme_optional}(([^'\\]|\\\\.|'[[:alnum:]])*)(\\\\*')([[:space:]]*[]},])/\1\2@@LMLINE_REDACTED@@\5\6/Ig"\
    -e "s/${auth_prefix_escaped_sq}${auth_scheme_optional}(([^'\\]|\\\\.|'[[:alnum:]])*\\\\?)('?)$/\1\2@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/${key_prefix_escaped_sq}(([^'\\]|\\\\.|'[[:alnum:]])*)(\\\\*')([[:space:]]*[]},])/\1@@LMLINE_REDACTED@@\5\6/Ig"\
    -e "s/${key_prefix_escaped_sq}(([^'\\]|\\\\.|'[[:alnum:]])*\\\\?)('?)$/\1@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/([?&/@#=;,])(\\\\+)\"([A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*)(\\\\+)\"/\1\"\3\"/Ig" \
    -e "s/([?&/@#=;,])(\\\\+)'([A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*)(\\\\+)'/\1'\3'/Ig" \
    -e "s/${auth_prefix}${auth_scheme}\"(([^\"\\\\]|\\\\.)*)\"/\1\2\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme_dq}(([^\"\\\\]|\\\\.)*)\"/\1\2@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme}'(([^'\\\\]|\\\\.)*)'/\1\2'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}${auth_scheme_sq}(([^'\\\\]|\\\\.)*)'/\1\2@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}${auth_scheme}\"(([^\"\\\\]|\\\\.)*\\\\?)$/\1\2\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_dq}(([^\"\\\\]|\\\\.)*\\\\?)$/\1\2@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme}'(([^'\\\\]|\\\\.)*\\\\?)$/\1\2'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}${auth_scheme_sq}(([^'\\\\]|\\\\.)*\\\\?)$/\1\2@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix_quoted_dq}${auth_scheme}@(([^\"\\\\]|\\\\.)*)(\"[[:space:]]|$)/\1\2##LMLINE_REDACTED##\5/Ig" \
    -e "s/${auth_prefix_quoted_sq}${auth_scheme}@(([^'\\\\]|\\\\.)*)('[[:space:]]|$)/\1\2##LMLINE_REDACTED##\5/Ig" \
    -e "s/${auth_prefix}${auth_scheme}@[^\\\"'[:space:]]*\\\"[^\\\"'[:space:]]*\\\"([[:space:]]|$)/\\1\\2##LMLINE_REDACTED##\\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme}@[^\\\"'[:space:]]*'[^\\\"'[:space:]]*'([[:space:]]|$)/\\1\\2##LMLINE_REDACTED##\\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme}@([^[:space:]\"']*)([[:space:]]+(-|https?:\\/\\/).*)$/\1\2##LMLINE_REDACTED##\4/Ig" \
    -e "s/${auth_prefix}${auth_scheme}@[^[:space:],]*(,[[:space:]]+)/\1\2##LMLINE_REDACTED##\3/Ig" \
    -e "/[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][\"']?[[:space:]]*:/ s/([,[:space:]])(nonce|response)=\"[^\"]*\"/\1\2=\"##LMLINE_REDACTED##\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme}@[^[:space:]]*.*$/\1\2##LMLINE_REDACTED##/Ig" \
    -e "s/##LMLINE_REDACTED##/@@LMLINE_REDACTED@@/Ig" \
    -e "s/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?(([^\"\\\\]|\\\\.)*\\\\\"([^\"\\\\]|\\\\.)*)(\"|$)/\\1\\2@@LMLINE_REDACTED@@\\6/Ig" \
    -e "s/(\"[^\"]*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?(([^\"\\\\]|\\\\.)+)(\"[[:space:]]|$)/\\1\\2@@LMLINE_REDACTED@@\\5/Ig" \
    -e "s/(\"Authorization[[:space:]]*:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)'([^\"\\\\]|\\\\.)*((\")|\\\\?\$)/\1\4/Ig" \
    -e "s/(^|[[:space:]])(Authorization[[:space:]]*:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)['\"]([^[:space:];,&|\\\\]|\\\\.)*/\1\2/Ig" \
    -e "s/('[^']*Authorization[[:space:]]*:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^']+)('[[:space:]]|$)/\\1\\2@@LMLINE_REDACTED@@\\4/Ig" \
    -e "s/('Authorization[[:space:]]*:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)\"([^'\\\\]|\\\\.)*((')|\\\\?\$)/\1\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme}(\\\\+)\"(([^\"\\\\]|\\\\.)*)(\\\\*)\"([^[:space:];,&|]*)/\1\2\3\"***REDACTED***\6\"\7/Ig" \
    -e "/Authorization[[:space:]]*:[[:space:]]+${auth_scheme_token}+[[:space:]]+\\\\+[\"]/!s/${auth_prefix}${auth_scheme}[^*@\\\"'[:space:];].*$/\1\2@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}\"(([^@\\\"\\\\]|\\\\.)*)\"/\\1\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}'(([^@'\\\\]|\\\\.)*)'/\\1'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}\"(([^\"\\\\]|\\\\.)*\\\\?)$/\\1\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}'(([^'\\\\]|\\\\.)*\\\\?)$/\\1'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}\"([^[:space:]\\\"\\\\]*@[^[:space:]\\\"\\\\]*)\"/\\1\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}'([^[:space:]'\\\\]*@[^[:space:]'\\\\]*)'/\\1'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}\"([^[:space:]\\\"\\\\]*@[^[:space:]\\\"\\\\]*)$/\\1\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}'([^[:space:]'\\\\]*@[^[:space:]'\\\\]*)$/\\1'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}\"(@[^\\\"\\\\]*)$/\\1\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}'(@[^'\\\\]*)$/\\1'@@LMLINE_REDACTED@@/Ig" \
    -e "s/(Authorization[[:space:]]*:[[:space:]]+(${auth_scheme_token}+[[:space:]]+)?[^[:space:]]*@@LMLINE_REDACTED@@[\"']?)[[:space:]]+[^[:space:]\\\"']+\"([[:space:]]|\|\||&&|&|[0-9]+[[:space:]]*>>|[0-9]+[[:space:]]*<<|[0-9]+[[:space:]]*[<>]|>>|<<|[|><]|\$)/\\1\\3/Ig" \
    -e "s/${auth_prefix}@[^[:space:]]*$/\\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}[^@\\\"'[:space:]]+\\\\$/\\1@@LMLINE_REDACTED@@\\\\/Ig" \
    -e "s/${auth_prefix}[^@\\\"'[:space:]]+$/\\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix}\"(([^\"\\\\]|\\\\.)*\\\\?)$/\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix}'(([^'\\\\]|\\\\.)*\\\\?)$/\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix}\"(([^\"\\\\]|\\\\.)*)\"/\1\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${key_prefix}('([^'\\\\]|\\\\.)*')/\1'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${key_prefix_quoted_dq}((${auth_scheme_name}[[:space:]]+)?([^\"[:space:];,&|<>\\\\]|\\\\.)+)\"/\\1\\3@@LMLINE_QUOTED_KEY@@\\3/Ig" \
    -e "s/${key_prefix_quoted_sq}((${auth_scheme_name}[[:space:]]+)?([^'[:space:];,&|<>\\\\]|\\\\.)+)'/\\1\\3@@LMLINE_QUOTED_KEY@@\\3/Ig" \
    -e ':lmline_key_chain_mark_loop' \
    -e "s/${key_prefix}([^'\"[:space:];,&|<>]+)([;,|&])([\"']?[A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*[\"']?[[:space:]]*[=:][[:space:]]*)/\1\7;@LMLINE_CHAIN_KEY@\8:\9/Ig" \
    -e 't lmline_key_chain_mark_loop' \
    -e "s/${key_prefix_url}([^\"'[:space:];,&|<>]+)([;,|&][[:space:]])/\\1'@@LMLINE_URL_REDACTED@@'\\8/Ig" \
    -e "s/${key_prefix_url}([^\"'[:space:];,&|<>]+)([;,|&]@LMLINE_CHAIN_KEY@[;,|&]:)/\\1'@@LMLINE_URL_REDACTED@@'\\8/g" \
    -e "s/(${key_prefix_url})([^[:space:]\"'#&?]+)(\?[A-Za-z_][A-Za-z0-9_-]*=)/\1'@@LMLINE_URL_REDACTED@@'\9/Ig" \
    -e "s/${key_prefix_url}([^[:space:]\"'#&]+)/\1'@@LMLINE_URL_REDACTED@@'/Ig" \
    -e 's/;@LMLINE_CHAIN_KEY@([;,|&]):/\1/g' \
    -e ':lmline_key_chain_loop' \
    -e "s/${key_prefix}([^'\"[:space:];,&|<>]+)([;,|&])([\"']?[A-Za-z0-9_-]*${key_word}[A-Za-z0-9_-]*[\"']?[[:space:]]*[=:][[:space:]]*)/\1'@@LMLINE_URL_REDACTED@@'\8\9/Ig" \
    -e 't lmline_key_chain_loop' \
    -e ':lmline_key_sep_loop' \
    -e "s/${key_prefix}([^\"'[:space:];,&|<>]+)([;,|&][[:space:]])/\1'@@LMLINE_URL_REDACTED@@'\8/Ig" \
    -e "s/${key_prefix}([^\"'[:space:];,&|<>]+)([\"\'])([;,|&][[:space:]])/\1'@@LMLINE_URL_REDACTED@@'\8\9/Ig" \
    -e 't lmline_key_sep_loop' \
    -e "s/${key_prefix}[^\"'[:space:]][^[:space:]]*/\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/[\"']@@LMLINE_QUOTED_KEY@@/@@LMLINE_REDACTED@@/Ig" \
    -e 's/(sk-[A-Za-z0-9_-]{12})[A-Za-z0-9_-]+/\1@@LMLINE_REDACTED@@/g' \
    -e 's/(sk_live_|sk_test_|rk_live_|rk_test_)[A-Za-z0-9_-]+/\1@@LMLINE_REDACTED@@/g' \
    -e 's/(ghp_|gho_|ghu_|ghs_|ghr_|github_pat_)[A-Za-z0-9_]+/\1@@LMLINE_REDACTED@@/g' \
    -e 's/(AKIA|ASIA|ABIA|ACCA|A3T[A-Z0-9])[A-Z0-9]+/\1@@LMLINE_REDACTED@@/g' \
    -e 's/(xox[a-z]-|xapp-)[A-Za-z0-9_-]+/\1@@LMLINE_REDACTED@@/g' \
    -e 's/(glpat-)[A-Za-z0-9_-]+/\1@@LMLINE_REDACTED@@/g' \
    -e 's/(AIza)[A-Za-z0-9_-]{35}[A-Za-z0-9_=-]*/\1@@LMLINE_REDACTED@@/g' \
    -e '/-----BEGIN[ A-Z0-9_-]*PRIVATE KEY/,/-----END[ A-Z0-9_-]*PRIVATE KEY/s/.*/***REDACTED PRIVATE KEY***/' \
    -e "s/##LMLINE_REDACTED##/***REDACTED***/Ig" \
    -e 's#@@LMLINE_QUOTED_SEMI@@#;//#g' \
    -e 's#@@LMLINE_QUOTED_COMMA@@#,//#g' \
    -e "s/'@@LMLINE_URL_REDACTED@@'/@@LMLINE_REDACTED@@/Ig" \
    -e "s/@@LMLINE_URL_REDACTED@@/@@LMLINE_REDACTED@@/Ig" \
    -e "s#(@@LMLINE_REDACTED@@[\"'])[[:space:]]+[^[:space:]\"']+([\"'])([[:space:],;]|\|\||&&|&|[0-9]+[[:space:]]*>>|[0-9]+[[:space:]]*<<|[0-9]+[[:space:]]*[<>]|>>|<<|[|><]|\$)#\\1\\3#g" \
    -e "s/(Authorization[[:space:]]*:[[:space:]]+@@LMLINE_REDACTED@@)[[:space:]]+\"[^\"]*\"/\\1 @@LMLINE_REDACTED@@/Ig" \
    -e "s/(Authorization[[:space:]]*:[[:space:]]+@@LMLINE_REDACTED@@)[[:space:]]+'[^']*'/\\1 @@LMLINE_REDACTED@@/Ig" \
    -e "s/;@LMLINE_SEP@/@@LMLINE_REDACTED@@/Ig" \
    -e "s/@LMLINE_CHAIN_KEY@/@@LMLINE_REDACTED@@/Ig" \
    -e "s/@LMLINE_SEP@/@@LMLINE_REDACTED@@/Ig" \
    -e "s/==LMLINE_AUTH_VALUE==/@@LMLINE_REDACTED@@/Ig" \
    -e "s/([&;,])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*[^[:space:]&;,=\"':=])([\"'[:space:]&;,]|$)/\1\2:***REDACTED***\6/Ig" \
    -e "s/([&;,])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*[:=]+)([[:space:]&;,]|$)/\1\2:***REDACTED***\6/Ig" \
    -e "s/([?][^[:space:]&;,]*)([&;,])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*[:=]+)([\"'])/\1\2\3:***REDACTED***\7/Ig" \
    -e 's#@@LMLINE_DBCMD@@##g' \
    -e "s/${encoded_mask}/***REDACTED***/Ig" \
    -e "s/@@LMLINE_REDACTED@@/***REDACTED***/Ig" | awk -v shield_lf="$cont_token_lf" -v shield_cr="$cont_token_cr" -v shield_protect="$cont_token_protect" -v raw_token="$cont_token" '
    BEGIN {
      bs = sprintf("%c", 92)
      cr = sprintf("%c", 13)
      nl = sprintf("%c", 10)
      repl_lf = bs nl
      repl_cr = bs cr nl
    }
    # Linear restoration: three literal-token passes replace the loop
    # that rescanned the tail for every shield. LF and CR shields are
    # restored before protection tokens so a restored raw token plus a
    # following LF cannot form a new LF shield in the same pass.
    {
      gsub(shield_lf, repl_lf)
      gsub(shield_cr, repl_cr)
      gsub(shield_protect, raw_token)
      printf "%s\n", $0
    }
  '
}
__lmline_prepare_clip_input() {
  local question=$1 clipboard=$2 provider=$3 max_input=${LMLINE_CLIP_MAX_INPUT_BYTES:-65536}
  local raw_bytes redacted input_bytes truncated=0 patterns_file realm_shield_prefix=${4-}
  [[ "$max_input" =~ ^[1-9][0-9]*$ ]] || max_input=65536
  raw_bytes=$(LC_ALL=C printf '%s' "$clipboard" | wc -c | tr -d ' ')
  redacted=$(printf '%s' "$clipboard" | __lmline_redact_clip_text "$realm_shield_prefix") || return 1
  input_bytes=$(LC_ALL=C printf '%s' "$redacted" | wc -c | tr -d ' ')
  if (( input_bytes > max_input )); then
    patterns_file=$(__lmline_condense_patterns_file) || return 1
    redacted=$(printf '%s' "$redacted" | __lmline_condense_text "$max_input" "$patterns_file") || return 1
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
  local tmp clipboard clip_input engine_output engine_status error had_errexit=0 max_output output_bytes meta_status provider display_status
  __lmline_next_realm_shield_prefix
  tmp=$(mktemp -d "$(__lmline_tmp_root)/lmline-clip.XXXXXX") || return 1
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
  clip_input=$(__lmline_prepare_clip_input "$question" "$clipboard" "$provider" "$__LMLINE_REALM_SHIELD_PREFIX") || {
    rm -rf "$tmp"
    return 1
  }
  printf '%s' "$clip_input" >"$tmp/line"
  __lmline_context_file "$tmp/context" "$question" clip || {
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
    error=$(printf '%s' "${engine_output:-engine exited with status $engine_status}" | __lmline_display_error_line 300)
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
    # Set the byte locale before expanding the substring, without changing the caller.
    display_status=0
    (LC_ALL=C; printf '%s\n' "${engine_output:0:max_output}") | __lmline_display_answer || display_status=$?
    printf '\n%sclip-output-truncated original_bytes=%s max_bytes=%s\n' "$prefix" "$output_bytes" "$max_output"
    (( display_status != 0 )) && return "$display_status"
    return 0
  fi
  printf '%s\n' "$engine_output" | __lmline_display_answer
}

__lmline_print_explanation() {
  local engine=$1 shell_name=$2 line=$3 point=$4 prefix=$5
  local tmp risk reason risk_match engine_output engine_status error had_errexit=0 max_output output_bytes meta_status display_status
  [[ -n "${line//[[:space:]]/}" ]] || {
    printf '%sno command to explain\n' "$prefix"
    return 0
  }
  tmp=$(mktemp -d "$(__lmline_tmp_root)/lmline-expl.XXXXXX") || return 1
  printf '%s' "$line" >"$tmp/line"
  __lmline_context_file "$tmp/context" "$line" explain || {
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
      error=$(printf '%s' "$engine_output" | __lmline_display_error_line 300)
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
    # Set the byte locale before expanding the substring, without changing the caller.
    display_status=0
    (LC_ALL=C; printf '%s\n' "${engine_output:0:max_output}") | __lmline_display_answer || display_status=$?
    printf '\n%sexplanation-truncated original_bytes=%s max_bytes=%s\n' "$prefix" "$output_bytes" "$max_output"
    (( display_status != 0 )) && return "$display_status"
    return 0
  fi
  printf '%s\n' "$engine_output" | __lmline_display_answer
}

__lmline_fix_run() {
  local line=$1 shell_name=$2 point=$3 engine=$4 n=$5 prefix=${6:-}
  local risk timeout max_output
  local tmp status engine_status backend context_text caller_functions exported_functions
  __lmline_reload_settings_if_changed "${__LMLINE_CONFIG_DIR:-${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}}"
  timeout=${LMLINE_FIX_TIMEOUT:-12}
  max_output=${LMLINE_FIX_MAX_OUTPUT:-12000}
  if ! __lmline_timeout_seconds_valid "$timeout"; then
    printf '%sinvalid LMLINE_FIX_TIMEOUT; expected a positive integer no greater than 2147483647\n' "$prefix" >&2
    return 3
  fi
  if [[ ! $max_output =~ ^[0-9]+$ ]]; then
    printf '%sinvalid LMLINE_FIX_MAX_OUTPUT; expected a nonnegative integer\n' "$prefix" >&2
    return 3
  fi

  tmp=$(mktemp -d "$(__lmline_tmp_root)/lmline-fix.XXXXXX") || return 1
  if ! backend=$(__lmline_select_exec_backend); then
    rm -rf "$tmp"
    case "$backend" in
      off) printf '%sfix execution disabled by LMLINE_EXEC_BACKEND=off\n' "$prefix" >&2 ;;
      microsandbox) printf '%smicrosandbox backend is unavailable; install msb, set LMLINE_MICROSANDBOX_COMMAND, or use LMLINE_EXEC_BACKEND=local\n' "$prefix" >&2 ;;
      invalid) printf '%sinvalid LMLINE_EXEC_BACKEND; expected auto, local, microsandbox, or off\n' "$prefix" >&2 ;;
      *) printf '%sexecution backend unavailable\n' "$prefix" >&2 ;;
    esac
    return 3
  fi
  if [[ "$backend" == local ]]; then
    risk=$(__lmline_risk_level "$line") || {
      rm -rf "$tmp"
      printf '%spolicy error\n' "$prefix" >&2
      return 3
    }
    case "$risk" in
      high)
        rm -rf "$tmp"
        printf '%sfix refused for high-risk command\n' "$prefix" >&2
        return 3
        ;;
      medium)
        if [[ "${LMLINE_FIX_ALLOW_MEDIUM:-0}" != 1 ]]; then
          rm -rf "$tmp"
          printf '%sfix refused for medium-risk command; set LMLINE_FIX_ALLOW_MEDIUM=1\n' "$prefix" >&2
          return 3
        fi
        ;;
    esac
  fi
  printf 'lmline-progress: re-running failed command via %s (timeout %ss)\n' "$backend" "$timeout"
  if ! __lmline_run_command_capture_with_backend "$backend" "$line" "$timeout" "$tmp/stdout" "$tmp/stderr"; then
    printf '%sfix execution failed via %s: %s\n' "$prefix" "$backend" "${__LMLINE_EXEC_ERROR:-unknown}" >&2
    if [[ -s "$tmp/stderr" ]]; then
      sed -n '1,5p' "$tmp/stderr" >&2
    fi
    rm -rf "$tmp"
    return 3
  fi
  status=$__LMLINE_EXEC_STATUS
  if ! __lmline_condense_file "$tmp/stdout" "$max_output" ||
    ! __lmline_condense_file "$tmp/stderr" "$max_output"; then
    rm -rf "$tmp"
    return 1
  fi
  if (( status == 0 )); then
    rm -rf "$tmp"
    printf '%scommand succeeded; no fix needed\n' "$prefix" >&2
    return 3
  fi

  printf 'lmline-progress: asking model for a fix (exit status %s)\n' "$status"
  engine_status=0
  # Caller-shell function names (names only, never bodies) for the engine
  # invocation only: reuse the bridge/engine snapshot when present, otherwise
  # collect locally when this is the matching Bash frontend. Kept
  # function-local and passed only on the engine command below, never
  # exported, so Copilot and context subprocesses never inherit it.
  # Same-process Copilot validation in a bridge child still sees the
  # non-exported snapshot.
  exported_functions=${__LMLINE_EXPORTED_FUNCTIONS-$(__lmline_collect_exported_functions)}
  caller_functions=
  if [[ -n ${__LMLINE_CALLER_FUNCTIONS-} ]]; then
    caller_functions=${__LMLINE_CALLER_FUNCTIONS}
  elif [[ "$shell_name" == bash && -n ${BASH_VERSION-} ]]; then
    if [[ -z ${LMLINE_SHELL_FUNCTIONS-} ]]; then
      caller_functions=$(__lmline_collect_shell_functions)
    else
      caller_functions=${LMLINE_SHELL_FUNCTIONS}
    fi
  elif [[ -n ${LMLINE_SHELL_FUNCTIONS-} ]]; then
    caller_functions=${LMLINE_SHELL_FUNCTIONS}
  fi
  if [[ "${LMLINE_FIX_BACKEND:-engine}" == copilot ]]; then
    context_text=$( {
      printf '## captured_execution\n'
      printf 'execution_backend=%s\n' "$backend"
      printf 'exit_status=%s\n' "$status"
      if [[ -s "$tmp/stderr" ]]; then
        __lmline_tool_data_block "STDERR" 10000 "${LMLINE_CONDENSE_LINE_BYTES:-2000}" <"$tmp/stderr"
      fi
      if [[ -s "$tmp/stdout" ]]; then
        __lmline_tool_data_block "STDOUT" 10000 "${LMLINE_CONDENSE_LINE_BYTES:-2000}" <"$tmp/stdout"
      fi
    } )
    __lmline_copilot_candidates "$line" "$point" "$shell_name" fix "$context_text" >"$tmp/engine" 2>&1 || engine_status=$?
  else
    __lmline_write_fix_input "$tmp/line" "$line" "$status" "$tmp/stdout" "$tmp/stderr" "$backend"
    __lmline_context_file "$tmp/context" "$line" fix
    if [[ -n $caller_functions ]]; then
      LMLINE_SHELL_FUNCTIONS="$caller_functions" LMLINE_EXPORTED_FUNCTIONS="$exported_functions" "$engine" --mode fix --shell "$shell_name" --cwd "$PWD" --point "$point" \
        --line-file "$tmp/line" --context-file "$tmp/context" --n "$n" >"$tmp/engine" 2>&1 || engine_status=$?
    else
      LMLINE_EXPORTED_FUNCTIONS="$exported_functions" "$engine" --mode fix --shell "$shell_name" --cwd "$PWD" --point "$point" \
        --line-file "$tmp/line" --context-file "$tmp/context" --n "$n" >"$tmp/engine" 2>&1 || engine_status=$?
    fi
  fi
  if (( engine_status != 0 )); then
    cat "$tmp/engine" >&2
    rm -rf "$tmp"
    return "$engine_status"
  fi
  # Engine output is already validated, deduplicated, and risk-annotated.
  grep '^lmline-candidate: \|^lmline-status: ' "$tmp/engine" || true
  rm -rf "$tmp"
}
