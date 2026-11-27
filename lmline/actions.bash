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
  local key_word key_name key_prefix_url
  local auth_prefix_escaped_dq auth_prefix_escaped_sq auth_scheme_optional
  local key_prefix_escaped_dq key_prefix_escaped_sq
  local auth_prefix_quoted_dq auth_prefix_quoted_sq auth_marker auth_redacted_value
  local realm_shield_prefix=${1-}
  local encoded_mask
  local userinfo_min=${LMLINE_CLIP_USERINFO_MIN-8}
  [[ -n $realm_shield_prefix ]] || return 1
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
  # one credential value.
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
  awk '
    BEGIN { sq = sprintf("%c", 39) }
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
    function scan(s, i,    c, out, n, w, k, prefix, rest, ch, rem, cluster_state) {
      out = ""
      n = length(s)
      scan_end = n + 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c ~ /[[:space:]]/) { out = out c; i++; continue }
        if (is_sep(c)) { out = out c; scan_end = i + 1; return out }
        parse_word(s, i)
        w = word_text
        k = word_end
        if (w == "--help" || w == "--version") {
          out = out w; i = k; continue
        }
        if (substr(w, 1, 1) == "-" && substr(w, 1, 2) != "--") {
          prefix = "-"
          rest = substr(w, 2)
          cluster_state = 0
          while (length(rest) > 0) {
            ch = substr(rest, 1, 1)
            if (ch == "v" || ch == "e" || ch == "T" || ch == "h") {
              prefix = prefix ch
              rest = substr(rest, 2)
              continue
            }
            if (ch == "p") {
              out = out prefix "p"
              rem = substr(rest, 2)
              if (rem != "") {
                out = out redact_value(rem)
                scan_end = k
                return out
              }
              i = k
              while (i <= n && substr(s, i, 1) ~ /[[:space:]]/) { out = out substr(s, i, 1); i++ }
              if (i <= n && !is_sep(substr(s, i, 1))) {
                parse_word(s, i)
                out = out redact_value(word_text)
                scan_end = word_end
              } else {
                scan_end = i
              }
              return out
            }
            if (ch == "f" || ch == "P" || ch == "d" || ch == "o") {
              out = out prefix ch
              rem = substr(rest, 2)
              if (rem != "") {
                out = out rem
                i = k
              } else {
                i = k
                while (i <= n && substr(s, i, 1) ~ /[[:space:]]/) { out = out substr(s, i, 1); i++ }
                if (i <= n && !is_sep(substr(s, i, 1))) {
                  parse_word(s, i); out = out word_text; i = word_end
                }
              }
              cluster_state = 1
              break
            }
            cluster_state = 2
            break
          }
          if (cluster_state == 0) {
            out = out prefix
            i = k
            continue
          }
          if (cluster_state == 1) {
            continue
          }
        }
        scan_end = i
        return out
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
    function process(s,    out, idx, before, after, seg, cut) {
      out = ""
      while ((idx = index(tolower(s), "sshpass")) > 0) {
        before = idx > 1 ? substr(s, idx - 1, 1) : ""
        after = substr(s, idx + 7, 1)
        if ((idx == 1 || is_before(before) || before == sq) &&
            (after == "" || is_after(after) || after == sq)) {
          out = out substr(s, 1, idx + 6)
          seg = scan(substr(s, idx + 7), 1)
          out = out seg
          cut = idx + 6 + scan_end
          s = substr(s, cut)
        } else {
          out = out substr(s, 1, idx + 6)
          s = substr(s, idx + 7)
        }
      }
      return out s
    }
    { print process($0) }
  ' | sed -E \
    -e "s/([?])(Authorization)([[:space:]]*[:=]+[[:space:]]*)(realm)=/\1\2\3${realm_shield_prefix}\4@@/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,\"']+[^[:space:]&;,\"']*=)((\\\\?[\"'])|[[:space:];,&<>|]|$)/\1\2:***REDACTED***\6/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*={2,}|[^[:space:]&;,=\"']*:+|([A-Za-z0-9+/]{4})*[A-Za-z0-9+/]{3}=)((\\\\?[\"'])|[[:space:];,&<>|]|$)/\1\2:***REDACTED***\7/Ig" \
    -e "s/([?])(Authorization)([[:space:]]*[:=]+[[:space:]]*)${realm_shield_prefix}([A-Za-z]+)@@/\1\2\3\4=/Ig" \
    -e "s/(^|[^[:alnum:]_-])(-u)([^[:space:]\"':;,|&<>=]+):(([^[:space:]\"';,&|<>\\\\]|\\\\.)+)(((\"[^\"]*\"|'[^']*')([^][:space:];,&|<>\"']*))*)/\\1\\2\\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^[:alnum:]_-])(-u)([^[:space:]\"':;,|&<>=]+):(((\"[^\"]*\"|'[^']*')([^][:space:];,&|<>\"']*))+)/\\1\\2\\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^[:alnum:]_-])(-u)([\"'])([^\"':]+):([^\"']+)([\"'])/\\1\\2\\3\\4:@@LMLINE_REDACTED@@\\6/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([^[:space:]\"':;,|&]+):(([^[:space:]\"';,&|<>\\\\]|\\\\.)+)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=)(([^[:space:]\"':;,|&<>\\\\]|\\\\.)+)([[:space:];,&|<>]|$)/\1\2@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/(^|[[:space:]])(--user=)([0-9]*(\\\\[^\"']|[^0-9[:space:]\"':;,|&<>])([^[:space:]\"':;,|&<>\\\\]|\\\\.)+)([[:space:];,&|<>]|$)/\1\2@@LMLINE_REDACTED@@\6/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)([\"'])([^[:space:]\"':]+):([^\"']+)([\"'])/\1\2\3\4:@@LMLINE_REDACTED@@\6/Ig" \
    -e "/@@LMLINE_REDACTED@@/!s/(^|[[:space:]])(-u=|--u=|--user=)([\"'])([^\"']+)([\"'])/\1\2\3@@LMLINE_REDACTED@@\5/Ig" \
    -e "s/(^|[[:space:]])(-u=|--u=|--user=)(\\\\*)\"([^[:space:]\"':]+):([^\"\\\\']*)(\\\\*)\"/\1\2\3\"\4:@@LMLINE_REDACTED@@\6\"/Ig" \
    -e "/@@LMLINE_REDACTED@@/!s/(^|[[:space:]])(-u=|--u=|--user=)(\\\\*)\"([^\"\\\\']*)(\\\\*)\"/\1\2\3\"@@LMLINE_REDACTED@@\5\"/Ig" \
    -e "s/(^|[[:space:]])(-u[[:space:]]+|--u[[:space:]]+|--user[[:space:]]+)([^[:space:]\"':;,|&]+):(([^[:space:]\"';,&|<>\\\\]|\\\\.)+)/\1\2\3:@@LMLINE_REDACTED@@/Ig" \
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
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+([^\\\"='[:space:];,&|]+)(\")([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+([^\\\"='[:space:];,&|]+)(')([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "s/${auth_prefix}(${auth_scheme_token}+)([:=]+)[[:space:]]+/\1\2\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:]+)([^\\\"'[:space:];,&|<>]*)([\"'])$/\1\2\3***REDACTED***\5/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"'[:space:];,&|]+)([[:space:]]+)/\1***REDACTED***\5/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"='[:space:];,&|]+)(\")([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[[:space:]]*\*/!s/${auth_prefix}${auth_scheme_name}([:=]+)([^\\\"='[:space:];,&|]+)(')([[:space:]]|$)/\1==LMLINE_AUTH_VALUE==\5\6/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)\"(([^\"\\\\]|\\\\.)*)\"/\\1\\2\\3\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme_name}([:=]+)'(([^'\\\\]|\\\\.)*)'/\\1\\2\\3'@@LMLINE_REDACTED@@'/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)\"(([^\"\\\\]|\\\\([^\"]))*)(\\\\+)\"/\1\2\3\4\"@@LMLINE_REDACTED@@\8\"/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)'(([^'\\\\]|\\\\([^']))*)(\\\\+)'/\1\2\3\4'@@LMLINE_REDACTED@@\8'/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)\"(([^\"\\\\]|\\\\([^\"]))*)\$/\1\2\3\4\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)\"(([^\"\\\\]|\\\\([^\"]))*\\\\)\$/\1\2\3\4\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)'(([^'\\\\]|\\\\([^']))*)\$/\1\2\3\4'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)(\\\\+)'(([^'\\\\]|\\\\([^']))*\\\\)\$/\1\2\3\4'@@LMLINE_REDACTED@@/Ig" \
    -e ':lmline_auth_scheme_seg_loop' \
    -e "s/(@@LMLINE_REDACTED@@(\\\\*[\"']|[\"']))(((\\\\*[\"']|[\"']))[^\"']*(\\\\*[\"']|[\"']))+/\1/Ig" \
    -e 't lmline_auth_scheme_seg_loop' \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)\"(([^\"\\\\]|\\\\.)*)$/\\1\\2\\3\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)\"(([^\"\\\\]|\\\\.)*\\\\)$/\\1\\2\\3\"@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)'(([^'\\\\]|\\\\.)*)$/\\1\\2\\3'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}${auth_scheme_any}([:=]+)'(([^'\\\\]|\\\\.)*\\\\)$/\\1\\2\\3'@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}([^\"'=[:space:];,&|][^\"'[:space:];,&|]*)([[:space:]]+)([\"'])/\\1@@LMLINE_REDACTED@@\\3\\4/Ig" \
    -e "s/${auth_prefix}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]*([>][>]|[<][<]|[|][|]|&&|[,;|&<>]))/\\1;@LMLINE_SEP@\\3/Ig" \
    -e "s/${auth_prefix}==LMLINE_AUTH_SCHEME==${auth_scheme}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]*)([>][>]|[<][<]|[|][|]|&&|[,;|&<>])/\1==LMLINE_AUTH_SCHEME==\2;@LMLINE_SEP@\4\5/Ig" \
    -e "s/${auth_prefix}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]+[0-9]+[[:space:]]*([>][>]|[<][<]|[<>]))/\\1;@LMLINE_SEP@\\3/Ig" \
    -e "s/${auth_prefix}==LMLINE_AUTH_SCHEME==${auth_scheme}([^\"'=[:space:];,&|<>][^\"'[:space:];,&|<>]*)([[:space:]]+[0-9]+[[:space:]]*)([>][>]|[<][<]|[<>])/\1==LMLINE_AUTH_SCHEME==\2;@LMLINE_SEP@\4\5/Ig" \
    -e 's/==LMLINE_AUTH_SCHEME==//Ig' \
    -e 's/(\"[^\"]*Authorization:[[:space:]]*'"${auth_redacted_value}"')\"/\1 \"/Ig' \
    -e "s/('[^']*Authorization:[[:space:]]*${auth_redacted_value})'/\1 '/Ig" \
    -e "s/(^|[^A-Za-z0-9_])([[:space:]]*)${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\\\"'=[:space:];,&|][^\\\"'[:space:];,&|]*)((\"[^\"']*\"|'[^']*'))+([^[:space:]\"';,&|]*)/\1\2\3\4\5@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^A-Za-z0-9_])([[:space:]]*)${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\\\\\"'=[:space:];,&|][^\\\\\"'[:space:];,&|]*)(\\\\+[\"])(([^[:space:];,&|\"'])*(\\\\+[\"']([^[:space:];,&|\"'])*)*)/\1\2\3\4\5@@LMLINE_REDACTED@@/Ig" \
    -e "s/(^|[^A-Za-z0-9_])([[:space:]]*)${auth_prefix}(${auth_scheme_token}+)([:=]+)([^\\\\\"'=[:space:];,&|][^\\\\\"'[:space:];,&|]*)(\\\\+['])(([^[:space:];,&|\"'])*(\\\\+[\"']([^[:space:];,&|\"'])*)*)/\1\2\3\4\5@@LMLINE_REDACTED@@/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"\"([^\"]*\\\\\"[^\"]*)\"[^[:space:]]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'(\"([^\"]*\\\\\"[^\"]*)\"|'[^']*\\\\.[^']*')[^[:space:]]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1\2@@LMLINE_REDACTED@@\"/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1\2@@LMLINE_REDACTED@@'/Ig" \
    -e ':auth_adjacent_loop' \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/((\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@\")(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1/Ig" \
    -e "/Authorization:[[:space:]]+[A-Za-z0-9+.-]*:[\*@]+/!s/(('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@')(\"[^\"']*\"|'[^']*')[^[:space:]\"']*/\1/Ig" \
    -e 't auth_adjacent_loop' \
    -e "s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"([0-9]+)([><])/\\1\\2@@LMLINE_REDACTED@@\\\"\\4\\5/Ig" \
    -e "s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'([0-9]+)([><])/\\1\\2@@LMLINE_REDACTED@@'\\4\\5/Ig" \
    -e 's/(\"[^\"]*Authorization:[[:space:]]*'"${auth_redacted_value}"')\"/\1 \"/Ig' \
    -e "s/('[^']*Authorization:[[:space:]]*${auth_redacted_value})'/\1 '/Ig" \
    -e "s/(\"[^\";,&|<>]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
    -e "s/(\"[^\"[:space:];,&|]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\\"]*)\"[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@\\\"/Ig" \
    -e "s/('[^';,&|<>]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
    -e "s/('[^'[:space:];,&|]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^[:space:]\\\\']*)'[^[:space:]';,&:<>]*/\\1\\2@@LMLINE_REDACTED@@'/Ig" \
    -e 's/("[^"]*Authorization:[^"]*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)) "/\1"/Ig' \
    -e "s/('[^']*Authorization:[^']*(\*\*\*REDACTED\*\*\*|@@LMLINE_REDACTED@@)) '/\1'/Ig" \
    -e "s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@\\\"/\\1\\2##LMLINE_REDACTED##\\\"/Ig" \
    -e "s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?@@LMLINE_REDACTED@@'/\\1\\2##LMLINE_REDACTED##'/Ig" \
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
    -e "s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?(([^\"\\\\]|\\\\.)*\\\\\"([^\"\\\\]|\\\\.)*)(\"|$)/\\1\\2@@LMLINE_REDACTED@@\\6/Ig" \
    -e "s/(\"[^\"]*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?(([^\"\\\\]|\\\\.)+)(\"[[:space:]]|$)/\\1\\2@@LMLINE_REDACTED@@\\5/Ig" \
    -e "s/(\"Authorization:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)'([^\"\\\\]|\\\\.)*((\")|\\\\?\$)/\1\4/Ig" \
    -e "s/(^|[[:space:]])(Authorization:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)['\"]([^[:space:];,&|\\\\]|\\\\.)*/\1\2/Ig" \
    -e "s/('[^']*Authorization:[[:space:]]+)(${auth_scheme_token}+[[:space:]]+)?([^']+)('[[:space:]]|$)/\\1\\2@@LMLINE_REDACTED@@\\4/Ig" \
    -e "s/('Authorization:[[:space:]]+${auth_scheme_token}+[:=]+@@LMLINE_REDACTED@@)\"([^'\\\\]|\\\\.)*((')|\\\\?\$)/\1\3/Ig" \
    -e "s/${auth_prefix}${auth_scheme}(\\\\+)\"(([^\"\\\\]|\\\\.)*)(\\\\*)\"([^[:space:];,&|]*)/\1\2\3\"***REDACTED***\6\"\7/Ig" \
    -e "/Authorization:[[:space:]]+${auth_scheme_token}+[[:space:]]+\\\\+[\"]/!s/${auth_prefix}${auth_scheme}[^@\\\"'[:space:];].*$/\1\2@@LMLINE_REDACTED@@/Ig" \
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
    -e "s/(Authorization:[[:space:]]+(${auth_scheme_token}+[[:space:]]+)?[^[:space:]]*@@LMLINE_REDACTED@@[\"']?)[[:space:]]+[^[:space:]\\\"']+\"([[:space:]]|\|\||&&|&|[0-9]+[[:space:]]*>>|[0-9]+[[:space:]]*<<|[0-9]+[[:space:]]*[<>]|>>|<<|[|><]|\$)/\\1\\3/Ig" \
    -e "s/${auth_prefix}@[^[:space:]]*$/\\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${auth_prefix}[^@\\\"'[:space:]]+\\\\$/\\1@@LMLINE_REDACTED@@\\\\/Ig" \
    -e "s/${auth_prefix}[^@\\\"'[:space:]]+$/\\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix}\"(([^\"\\\\]|\\\\.)*\\\\?)$/\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix}'(([^'\\\\]|\\\\.)*\\\\?)$/\1@@LMLINE_REDACTED@@/Ig" \
    -e "s/${key_prefix}\"(([^\"\\\\]|\\\\.)*)\"/\1\"@@LMLINE_REDACTED@@\"/Ig" \
    -e "s/${key_prefix}('([^'\\\\]|\\\\.)*')/\1'@@LMLINE_REDACTED@@'/Ig" \
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
    -e "s/(Authorization:[[:space:]]+@@LMLINE_REDACTED@@)[[:space:]]+\"[^\"]*\"/\\1 @@LMLINE_REDACTED@@/Ig" \
    -e "s/(Authorization:[[:space:]]+@@LMLINE_REDACTED@@)[[:space:]]+'[^']*'/\\1 @@LMLINE_REDACTED@@/Ig" \
    -e "s/;@LMLINE_SEP@/@@LMLINE_REDACTED@@/Ig" \
    -e "s/@LMLINE_CHAIN_KEY@/@@LMLINE_REDACTED@@/Ig" \
    -e "s/@LMLINE_SEP@/@@LMLINE_REDACTED@@/Ig" \
    -e "s/==LMLINE_AUTH_VALUE==/@@LMLINE_REDACTED@@/Ig" \
    -e "s/([&;,])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*[^[:space:]&;,=\"':=])([\"'[:space:]&;,]|$)/\1\2:***REDACTED***\6/Ig" \
    -e "s/([&;,])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*[:=]+)([[:space:]&;,]|$)/\1\2:***REDACTED***\6/Ig" \
    -e "s/([?][^[:space:]&;,]*)([&;,])(Authorization)([[:space:]]*[:=][[:space:]]*)([-A-Za-z0-9._~%+]+[[:space:]])?([^[:space:]&;,=\"']*[:=]+)([\"'])/\1\2\3:***REDACTED***\7/Ig" \
    -e 's#@@LMLINE_DBCMD@@##g' \
    -e "s/${encoded_mask}/***REDACTED***/Ig" \
    -e "s/@@LMLINE_REDACTED@@/***REDACTED***/Ig"
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
