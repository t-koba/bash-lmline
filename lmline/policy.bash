#!/usr/bin/env bash

# Candidate validation and insertion policy for lmline. This file is meant to be sourced.

__LMLINE_POLICY_DIR=${BASH_SOURCE[0]%/*}
[[ $__LMLINE_POLICY_DIR == "${BASH_SOURCE[0]}" ]] && __LMLINE_POLICY_DIR=.
__LMLINE_POLICY_DIR=$(cd -- "$__LMLINE_POLICY_DIR" && pwd -P)
if ! declare -F __lmline_resolve_data_file >/dev/null 2>&1; then
  # shellcheck source=lmline/config.bash
  source "$__LMLINE_POLICY_DIR/config.bash"
fi
__lmline_init_dirs "$__LMLINE_POLICY_DIR"
: "${LMLINE_MAX_CANDIDATE_BYTES:=4096}"

# Word lists are read once per shell process; candidate validation checks every
# word of every candidate, so per-word file reads and grep forks add up.
__lmline_word_is_policy_skip() {
  local word=$1 file
  if [[ -z "${__LMLINE_SHELL_SYNTAX_WORDS_CACHE_SET:-}" ]]; then
    file=$(__lmline_resolve_data_file shell_syntax_words \
      "${LMLINE_SHELL_SYNTAX_WORDS_FILE:-}" \
      "$LMLINE_USER_RULES_DIR/shell_syntax_words.txt" \
      "$LMLINE_DEFAULTS_DIR/shell_syntax_words.txt") || return 1
    __LMLINE_SHELL_SYNTAX_WORDS_CACHE=$(__lmline_read_list_file "$file")
    __LMLINE_SHELL_SYNTAX_WORDS_CACHE_SET=1
  fi
  [[ $'\n'"$__LMLINE_SHELL_SYNTAX_WORDS_CACHE"$'\n' == *$'\n'"$word"$'\n'* ]]
}

__lmline_word_is_command_prefix() {
  local word=$1 file
  if [[ -z "${__LMLINE_COMMAND_PREFIX_WORDS_CACHE_SET:-}" ]]; then
    file=$(__lmline_resolve_data_file command_prefix_words \
      "${LMLINE_COMMAND_PREFIX_WORDS_FILE:-}" \
      "$LMLINE_USER_RULES_DIR/command_prefix_words.txt" \
      "$LMLINE_DEFAULTS_DIR/command_prefix_words.txt") || return 1
    __LMLINE_COMMAND_PREFIX_WORDS_CACHE=$(__lmline_read_list_file "$file")
    __LMLINE_COMMAND_PREFIX_WORDS_CACHE_SET=1
  fi
  [[ $'\n'"$__LMLINE_COMMAND_PREFIX_WORDS_CACHE"$'\n' == *$'\n'"$word"$'\n'* ]]
}

__lmline_normalize_candidate_line() {
  sed -E \
    -e 's/^[[:space:]]+//' \
    -e 's/[[:space:]]+$//' \
    -e 's/^[[:space:]]*[-*][[:space:]]+//' \
    -e 's/^[[:space:]]*[0-9]+[.)][[:space:]]+//' \
    -e 's/^`//' \
    -e 's/`$//'
}

__lmline_filter_candidates() {
  awk '{
    t=$0
    sub(/^[[:space:]]+/, "", t)
    sub(/[[:space:]]+$/, "", t)
    if (length(t) > 0 && t !~ /^```[[:alpha:]]*[[:space:]]*$/) print
  }' |
    __lmline_normalize_candidate_line |
    awk 'length > 0'
}

__lmline_candidate_truncated() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096} byte_len
  byte_len=$(LC_ALL=C printf '%s' "$cmd" | wc -c)
  (( byte_len > max_len ))
}

__lmline_truncate_candidate() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096}
  printf '%s' "$cmd" | LC_ALL=C cut -c "1-$max_len"
}

__lmline_truncated_comment_candidate() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096} prefix="# TRUNCATED: " prefix_len body_len
  prefix_len=$(LC_ALL=C printf '%s' "$prefix" | wc -c | tr -d ' ')
  body_len=$((max_len - prefix_len))
  (( body_len > 0 )) || { __lmline_truncate_candidate "$cmd"; return 0; }
  printf '%s' "$prefix"
  printf '%s' "$cmd" | LC_ALL=C cut -c "1-$body_len"
}

__lmline_valid_candidates() {
  local candidate reason
  while IFS= read -r candidate; do
    if __lmline_candidate_truncated "$candidate"; then
      candidate=$(__lmline_truncate_candidate "$candidate")
      reason=$(__lmline_candidate_rejection_reason "$candidate")
      [[ "$reason" == ok ]] || candidate=$(__lmline_truncated_comment_candidate "$candidate")
    fi
    __lmline_validate_candidate "$candidate" && printf '%s\n' "$candidate"
  done < <(__lmline_filter_candidates)
  return 0
}

__lmline_validate_candidate() {
  local cmd=$1 mode=${2:-}
  [[ $(__lmline_candidate_rejection_reason "$cmd" "$mode") == ok ]]
}

__lmline_candidate_rejection_reason() {
  local cmd=$1 mode=${2:-}
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" != *$'\n'* ]] || { printf 'multiline'; return 0; }
  [[ "$cmd" != *$'\r'* ]] || { printf 'carriage-return'; return 0; }
  [[ ! "$cmd" =~ ^[[:space:]]*\`\`\`[[:alpha:]]*[[:space:]]*$ ]] || { printf 'markdown-fence'; return 0; }
  if [[ "$cmd" == *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']* ]]; then
    printf 'control-character'
    return 0
  fi
  if [[ "$mode" == fix ]]; then
    [[ "$cmd" != "## "* && "$cmd" != "### "* ]] || { printf 'fix-heading'; return 0; }
    [[ "$cmd" != exit_status=* ]] || { printf 'fix-status'; return 0; }
  fi
  [[ "$cmd" == "# TRUNCATED: "* || "$cmd" == "# REVIEW REQUIRED: "* ]] && { printf 'ok'; return 0; }
  bash -n -c "$cmd" >/dev/null 2>&1 || { printf 'shell-syntax'; return 0; }
  __lmline_reject_env_only_pipeline "$cmd" || { printf 'env-only-command-segment'; return 0; }
  __lmline_reject_directory_file_operands "$cmd" || { printf 'directory-file-operand'; return 0; }
  __lmline_validate_commands_available "$cmd" || { printf 'command-not-found'; return 0; }
  printf 'ok'
}

__lmline_split_pipeline() {
  local cmd=$1 keep_quoted=${2:-0} extra_seps=${3:-}
  local stripped="" i ch quote="" prev=""
  for ((i = 0; i < ${#cmd}; i++)); do
    ch=${cmd:i:1}
    if [[ -n "$quote" ]]; then
      if [[ "$quote" == '"' && "$ch" == '\' && "$prev" != '\' ]]; then
        prev=$ch
        (( keep_quoted )) && stripped+=$ch
        continue
      fi
      if [[ "$ch" == "$quote" && "$prev" != '\' ]]; then
        quote=
      fi
      (( keep_quoted )) && stripped+=$ch
      prev=$ch
      continue
    fi
    case "$ch" in
      "'"|'"'|'`')
        quote=$ch
        (( keep_quoted )) && stripped+=$ch
        ;;
      '|'|';'|'&') stripped+=$'\n' ;;
      *)
        if [[ -n "$extra_seps" && "$extra_seps" == *"$ch"* ]]; then
          stripped+=$'\n'
        else
          stripped+=$ch
        fi
        ;;
    esac
    prev=$ch
  done
  printf '%s\n' "$stripped"
}

__lmline_reject_env_only_pipeline() {
  local cmd=$1 stripped segment token saw_non_assignment
  stripped=$(__lmline_split_pipeline "$cmd" 0)

  while IFS= read -r segment; do
    saw_non_assignment=0
    for token in $segment; do
      case "$token" in
        [A-Za-z_]*=*) continue ;;
        *) saw_non_assignment=1; break ;;
      esac
    done
    [[ -z "${segment//[[:space:]]/}" || $saw_non_assignment -eq 1 ]] || return 1
  done <<<"$stripped"
  return 0
}

__lmline_reject_directory_file_operands() {
  local cmd=$1 stripped segment
  stripped=$(__lmline_split_pipeline "$cmd" 1)

  while IFS= read -r segment; do
    __lmline_segment_has_directory_file_operand "$segment" && return 1
  done <<<"$stripped"
  return 0
}

__lmline_unquote_simple_word() {
  local word=$1
  word=${word#\"}; word=${word%\"}
  word=${word#\'}; word=${word%\'}
  printf '%s\n' "$word"
}

__lmline_segment_has_directory_file_operand() {
  local segment=$1 cmd="" token next_is_arg=0 operand
  local -a words
  read -r -a words <<<"$segment"
  ((${#words[@]} > 0)) || return 1

  for token in "${words[@]}"; do
    [[ "$token" == *=* && "$token" != /* && "$token" != ./* && "$token" != ../* ]] && continue
    case "$token" in
      command|builtin|exec|env|time|sudo|'!') continue ;;
    esac
    cmd=$(__lmline_unquote_simple_word "$token")
    break
  done
  case "$cmd" in
    head|tail|cat|less|more|wc|sort|uniq|nl|rev|tac|paste|fold|expand|unexpand) ;;
    *) return 1 ;;
  esac

  next_is_arg=0
  for token in "${words[@]:1}"; do
    token=$(__lmline_unquote_simple_word "$token")
    [[ -n "$token" ]] || continue
    if (( next_is_arg == 1 )); then
      next_is_arg=0
      continue
    fi
    case "$token" in
      --) continue ;;
      -n|-c|--lines|--bytes|--pid|--sleep-interval|--max-unchanged-stats)
        next_is_arg=1
        continue
        ;;
      -*) continue ;;
    esac
    operand=$token
    [[ "$operand" == *[\*\?\[]* ]] && continue
    [[ -d "$operand" ]] && return 0
  done
  return 1
}

__lmline_risk_level() {
  local cmd=$1 match status
  match=$(__lmline_risk_match "$cmd")
  status=$?
  (( status == 0 )) || return "$status"
  if [[ -n "$match" ]]; then
    printf '%s\n' "${match%%$'\t'*}"
  else
    printf 'low\n'
  fi
}

__lmline_risk_reason() {
  local cmd=$1 match status
  match=$(__lmline_risk_match "$cmd")
  status=$?
  (( status == 0 )) || return "$status"
  if [[ -n "$match" ]]; then
    printf '%s\n' "${match#*$'\t'}"
  else
    printf 'no matching risk rule\n'
  fi
}

# Decode $'...' ANSI-C quoting for risk matching only (not execution) with the
# shell's own %b expansion, so hex/octal hides like $'\x72\x6d' are judged by
# the same rules as their bare forms. A trailing unbalanced $'... is left
# as-is for the unresolved-variable fallback in __lmline_risk_match.
__lmline_decode_ansi_c_for_risk() {
  local str=$1 out="" pre rest inner ch i j esc decoded
  [[ $str == *"\$'"* ]] || { printf '%s' "$str"; return 0; }
  while [[ $str == *"\$'"* ]]; do
    pre=${str%%"\$'"*}
    rest=${str#*"\$'"}
    inner=""
    esc=0
    j=-1
    for ((i = 0; i < ${#rest}; i++)); do
      ch=${rest:i:1}
      if (( esc )); then
        inner+="\\$ch"
        esc=0
        continue
      fi
      if [[ $ch == '\\' ]]; then
        esc=1
        continue
      fi
      if [[ $ch == "'" ]]; then
        j=$i
        break
      fi
      inner+="$ch"
    done
    if (( j < 0 )); then
      out+="$pre\$'$rest"
      str=""
      break
    fi
    printf -v decoded '%b' "$inner" 2>/dev/null || decoded="$inner"
    out+="$pre$decoded"
    str=${rest:$((j + 1))}
  done
  out+="$str"
  printf '%s' "$out"
}

# Minimal fail-closed canonicalization for risk matching only (not execution).
# Strips quoting/backslash escapes (including legacy backtick command
# substitution, symmetric with the paren handling that already covers $())
# and normalizes $IFS/${IFS} to a space so
# trivially quoted forms ('"rm" -rf', 'rm${IFS}-rf') match the same rules as
# their bare forms. Also normalizes pipe spacing (so 'a|sh' matches '| sh'),
# command separators (so ';eval' matches ' eval '), absolute command
# paths after a pipe (so '| /bin/sh' matches '| sh'), and brace expansion
# (so '{rm,-rf,/tmp/x}' matches ' rm -rf /tmp/x '). Deliberately small:
# no AST or full deobfuscation; ANSI-C decoding and the unresolved-variable
# fallback live in __lmline_risk_match.
__lmline_canonicalize_for_risk() {
  sed -E -e 's/\$\{?IFS\}?/ /g' -e 's/\\(.)/\1/g' -e "s/'//g" -e 's/"//g' -e 's/`//g' \
    -e 's/\|\|/ /g' -e 's/\|/ | /g' -e 's/[;&()]/ /g' -e 's/[{},]/ /g' \
    -e 's#\|[[:space:]]*/[^[:space:]|;()&]*/#| #g'
}

# Expand brace groups for risk matching only (not execution) without eval,
# so prefix-split hides like ev{al,xx} are judged by each alternative
# (eval/evxx) and whole-word groups like {rm,-rf,/tmp/x} by their joined
# words. Groups without a comma or .. are literal in bash (r{m} stays r{m}),
# so their braces become spaces. Output is one alternative per line; a
# non-zero exit means the expansion was capped and the caller must fail
# closed. Pure string surgery: never executes command substitution.
# Newline-delimited strings (not arrays) keep this safe under set -u on
# bash 4.2, where expanding an empty array is an unbound-variable error.
# A brace group counts as a standalone word (joined with spaces) when it is
# not glued to other word characters: empty or adjacent to whitespace or a
# shell separator, which __lmline_canonicalize_for_risk normalizes to spaces
# anyway. Prefix-glued groups (ev{al,xx}, project/{src,tests}) stay split
# into per-alternative expansions.
__lmline_brace_at_word_boundary() {
  case "$1" in
    ""|[[:space:]]|\;|\&|\||\(|\)) return 0 ;;
  esac
  return 1
}

__lmline_expand_braces_for_risk() {
  local current=$1 next="" s pre inner post joined o opts_rest a b mid rest
  local iter=0 changed=0 count=0 ob cb
  printf -v ob "\001"
  printf -v cb "\002"
  # Hide ${...} parameter-expansion braces first: they are not brace
  # expansion (rm${IFS}-rf must survive for the IFS rule, ${X=rm} for the
  # unresolved-variable fallback), so their braces must not be expanded
  # or spaced. Placeholders are restored at the end.
  while [[ $current == *'${'* ]]; do
    pre=${current%%'${'*}
    rest=${current#*'${'}
    [[ $rest == *}* ]] || break
    mid=${rest%%\}*}
    post=${rest#*\}}
    current="${pre}\$${ob}${mid}${cb}${post}"
  done
  while (( iter++ < 20 )); do
    next=""
    changed=0
    count=0
    while IFS= read -r s || [[ -n $s ]]; do
      if [[ $s =~ (.*)\{([^{}]*)\}(.*) ]]; then
        pre=${BASH_REMATCH[1]}
        inner=${BASH_REMATCH[2]}
        post=${BASH_REMATCH[3]}
        if [[ $inner == *,* ]]; then
          if __lmline_brace_at_word_boundary "${pre: -1}" && __lmline_brace_at_word_boundary "${post:0:1}"; then
            joined=${inner//,/ }
            next+="${pre}${joined}${post}"$'\n'
          else
            opts_rest=$inner
            while [[ $opts_rest == *,* ]]; do
              o=${opts_rest%%,*}
              next+="${pre}${o}${post}"$'\n'
              opts_rest=${opts_rest#*,}
              (( count += 1 ))
              (( count <= 64 )) || return 1
            done
            next+="${pre}${opts_rest}${post}"$'\n'
          fi
          changed=1
        elif [[ $inner == *..* ]]; then
          a=${inner%%..*}
          b=${inner#*..}
          if __lmline_brace_at_word_boundary "${pre: -1}" && __lmline_brace_at_word_boundary "${post:0:1}"; then
            next+="${pre}${a} ${b}${post}"$'\n'
          else
            next+="${pre}${a}${post}"$'\n'"${pre}${b}${post}"$'\n'
          fi
          changed=1
        else
          next+="${pre} ${inner} ${post}"$'\n'
          changed=1
        fi
      else
        next+="$s"$'\n'
      fi
      (( count += 1 ))
      (( count <= 64 )) || return 1
    done <<<"$current"
    current=$next
    (( changed )) || break
  done
  current=${current//$'\x01'/'{'}
  current=${current//$'\x02'/'}'}
  printf '%s' "$current"
}

# Structural pipe-to-shell check for risk matching only (not execution).
# Any non-first pipeline segment whose command word (after stripping
# wrapper prefixes, options, assignments, quoting and absolute paths) is an
# interactive shell executes piped stdin as code. Judging the command word
# structurally replaces enumerating wrapper/prefix combinations in
# risk_patterns.tsv and closes flag variants like 'env -i sh' that patterns
# miss. Only the sh family is judged here: piping a local file to python
# and similar interpreters is ordinary use and stays low unless a
# downloader-specific pattern matches.
__lmline_risk_piped_shell() {
  local cmd=$1 stripped segment token word cmdword base
  local -a words
  stripped=$(__lmline_split_pipeline "$cmd" 1)
  local idx=0
  while IFS= read -r segment || [[ -n $segment ]]; do
    idx=$((idx + 1))
    (( idx > 1 )) || continue
    [[ -n "${segment//[[:space:]()]/}" ]] || continue
    read -r -a words <<<"$segment" || continue
    cmdword=""
    local skip_next=0
    for token in "${words[@]}"; do
      word=$(__lmline_unquote_simple_word "$token")
      word=${word//[()]/}
      [[ -n "$word" ]] || continue
      if (( skip_next )); then
        skip_next=0
        continue
      fi
      case "$word" in
        [A-Za-z_]*=*) continue ;;
        # Wrapper options that consume the next token (exec -a name,
        # env/sudo -u name, sudo -g group, nice -n level): skip the value
        # too, or it misreads as the command word (observed: nice -n 10 sh
        # scored low). Deliberately excludes -p, which takes no value for
        # command/time (time -p sh) but does for sudo (already high via the
        # sudo rule), so skipping there would regress.
        -a|-u|-g|-n) skip_next=1; continue ;;
        -*) continue ;;
        command|builtin|exec|env|time|sudo|nohup|nice|'!') continue ;;
      esac
      word=${word#\`}; word=${word%\`}
      [[ -n "$word" ]] || continue
      cmdword=$word
      break
    done
    [[ -n "$cmdword" ]] || continue
    base=${cmdword##*/}
    case "$base" in
      sh|bash|dash|ksh|zsh) return 0 ;;
    esac
  done <<<"$stripped"
  return 1
}

__lmline_risk_match() {
  local cmd=$1 expanded file line level pattern reason alt canon alts_str
  local brace_capped=0 best_level="" best_reason=""
  # Decode ANSI-C quoting first so hex/octal hides are judged by content.
  expanded=$(__lmline_decode_ansi_c_for_risk "$cmd")
  if alts_str=$(__lmline_expand_braces_for_risk "$expanded"); then
    brace_capped=0
  else
    alts_str=$expanded
    brace_capped=1
  fi
  [[ -n $alts_str ]] || alts_str=$expanded
  file=$(__lmline_resolve_data_file risk_patterns \
    "${LMLINE_RISK_PATTERNS_FILE:-}" \
    "$LMLINE_USER_RULES_DIR/risk_patterns.tsv" \
    "$LMLINE_DEFAULTS_DIR/risk_patterns.tsv") || return 1
  while IFS= read -r alt || [[ -n $alt ]]; do
    # Normalize: canonicalize quoting/IFS/braces, squeeze whitespace, and
    # wrap in single spaces so one pattern like "* dd *" matches at line
    # start, mid-pipeline, and bare.
    if __lmline_risk_piped_shell "$alt"; then
      printf 'high\tpiped shell execution\n'
      return 0
    fi
    canon=$(__lmline_canonicalize_for_risk <<<"$alt" | tr -s '[:space:]' ' ')
    canon=${canon# }
    canon=${canon% }
    canon=" $canon "
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      IFS=$'\t' read -r level pattern reason <<<"$line"
      [[ -n "$level" && -n "$pattern" ]] || continue
      case "$level" in high|medium|low) ;; *) continue ;; esac
      if [[ "$canon" == $pattern ]]; then
        case "$level" in
          high)
            printf '%s\t%s\n' "$level" "${reason:-matched policy rule}"
            return 0
            ;;
          medium)
            [[ $best_level == "medium" ]] || { best_level="medium"; best_reason="${reason:-matched policy rule}"; }
            ;;
          low)
            [[ -n $best_level ]] || { best_level="low"; best_reason="${reason:-matched policy rule}"; }
            ;;
        esac
        break
      fi
    done <"$file"
  done <<<"$alts_str"
  if [[ -n $best_level ]]; then
    printf '%s\t%s\n' "$best_level" "$best_reason"
    return 0
  fi
  if __lmline_risk_has_unresolved_var_command "$expanded"; then
    printf 'medium\tunresolved variable command\n'
    return 0
  fi
  if (( brace_capped )); then
    printf 'medium\tunresolved brace expansion\n'
    return 0
  fi
}

# Fail-closed net for variable indirection in the command word ($VAR, ${VAR},
# or surviving $'...' residue): the value cannot be proven safe, so report
# medium and let the insert warning and fix-mode gating apply. Concrete words
# (echo $HOME), $(...) substitution (judged by its content rules), and
# path-like $HOME/... are left alone: no stricter than needed.
__lmline_risk_has_unresolved_var_command() {
  local cmd=$1 stripped segment token dt
  stripped=$(__lmline_split_pipeline "$cmd" 1)
  while IFS= read -r segment; do
    for token in $segment; do
      [[ -n $token ]] || continue
      case "$token" in
        [A-Za-z_]*=*) continue ;;
        \'*) break ;;
      esac
      dt=${token#\"}
      dt=${dt%\"}
      case "$dt" in
        '$('*) break ;;
        '$'*)
          [[ $dt == */* ]] && break
          return 0
          ;;
        *) break ;;
      esac
    done
  done <<<"$stripped"
  return 1
}

__lmline_extract_command_words() {
  local cmd=$1 stripped segment token
  # A conservative lexical approximation: split at command separators and keep
  # the first simple command word after env assignments, negation, and builtins.
  stripped=$(__lmline_split_pipeline "$cmd" 0 "()")

  while IFS= read -r segment; do
    for token in $segment; do
      [[ "$token" == *=* && "$token" != /* && "$token" != ./* && "$token" != ../* ]] && continue
      if __lmline_word_is_command_prefix "$token"; then
        continue
      fi
      case "$token" in
        [{\<\>\&]*)
          continue
          ;;
      esac
      token=${token#\"}; token=${token%\"}
      token=${token#\'}; token=${token%\'}
      token=${token#\`}; token=${token%\`}
      [[ -n "$token" && "$token" != '$'* ]] && printf '%s\n' "$token"
      break
    done
  done <<<"$stripped"
}

__lmline_validate_commands_available() {
  local cmd=$1
  local word
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    [[ "$word" == */* ]] && continue
    __lmline_word_is_policy_skip "$word" && continue
    command -v "$word" >/dev/null 2>&1 || return 1
  done < <(__lmline_extract_command_words "$cmd")
  return 0
}
