#!/usr/bin/env bash

# Candidate validation and insertion policy for lmline. This file is meant to be sourced.

__LMLINE_POLICY_DIR=${BASH_SOURCE[0]%/*}
[[ $__LMLINE_POLICY_DIR == "${BASH_SOURCE[0]}" ]] && __LMLINE_POLICY_DIR=.
if [[ ${__LMLINE_DIR-} != "$__LMLINE_POLICY_DIR" ]]; then
  __LMLINE_POLICY_DIR=$(cd -- "$__LMLINE_POLICY_DIR" && pwd -P)
fi
if ! declare -F __lmline_resolve_data_file >/dev/null 2>&1; then
  # shellcheck source=lmline/config.bash
  source "$__LMLINE_POLICY_DIR/config.bash"
fi
__lmline_init_dirs "$__LMLINE_POLICY_DIR"
: "${LMLINE_MAX_CANDIDATE_BYTES:=4096}"
# shellcheck source=lmline/validation-boundary.bash
source "$__LMLINE_POLICY_DIR/validation-boundary.bash"

# Syntax-only zsh probe. Zsh creates process-substitution files in the current
# directory even under -n, so the probe parses from a writable directory in a
# subshell; the caller's cwd stays put and candidate text is never executed.
# Status: 0 valid, 1 syntax rejection, 2 validator unavailable/inconclusive.
__lmline_zsh_syntax_probe() {
  command -v zsh >/dev/null 2>&1 || return 2
  local probe_dir=${TMPDIR:-/tmp} status
  [[ -d "$probe_dir" && -w "$probe_dir" ]] || probe_dir=/tmp
  [[ -d "$probe_dir" && -w "$probe_dir" ]] || return 2
  (
    cd -- "$probe_dir" 2>/dev/null || exit 2
    command zsh -f -n -c "$1" >/dev/null 2>&1
  )
  status=$?
  case $status in
    0|1) return "$status" ;;
    *) return 2 ;;
  esac
}

# Word lists are read once per shell process; candidate validation checks every
# word of every candidate, so per-word file reads and grep forks add up.
__lmline_word_is_policy_skip() {
  local word=$1 file
  # This vocabulary also contains builtins and ordinary programs. Only
  # structural syntax may bypass target-shell availability: a listed command
  # still needs a real builtin/PATH binding after position-local functions
  # have been resolved by the scanner.
  case "$word" in
    '[['|']]'|'{'|'}'|'!'|case|do|done|else|'esac'|fi|for|if|in|then|time|until|while) ;;
    *) return 1 ;;
  esac
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

# A program that runs a command string given to it: the command it carries
# is the command that runs, so both the piped-shell check and the removal
# family ask this one owner. The list is a shipped data file, so a user can
# add a program the shipped list does not name.
__lmline_word_is_shell() {
  local word=$1 file
  if [[ -z "${__LMLINE_SHELL_WORDS_CACHE_SET:-}" ]]; then
    file=$(__lmline_resolve_data_file shell_words \
      "${LMLINE_SHELL_WORDS_FILE:-}" \
      "$LMLINE_USER_RULES_DIR/shell_words.txt" \
      "$LMLINE_DEFAULTS_DIR/shell_words.txt") || return 1
    __LMLINE_SHELL_WORDS_CACHE=$(__lmline_read_list_file "$file")
    __LMLINE_SHELL_WORDS_CACHE_SET=1
  fi
  [[ $'\n'"$__LMLINE_SHELL_WORDS_CACHE"$'\n' == *$'\n'"$word"$'\n'* ]]
}

# Programs that run another program given to them, so the command they carry
# is the command that runs, and the operands of their own that stand between
# the program and that command. One owner for this vocabulary: the removal
# family and the pipe-to-shell gate both ask it. The sh family runs a command
# string and is named in shell_words.txt.
__lmline_risk_runner_operands() {
  # An optional second argument supplies the quote-preserving source when a
  # caller joins words that it decoded from a structural segment.
  local -a decoded=() structural_words=()
  local structural_source=${2:-$1} structural_line
  mapfile -t decoded < <(__lmline_risk_split_words "$1")
  local runner=${decoded[0]:-$1} i named
  case "${runner##*/}" in
    chroot|flock|su) printf '1\n' ;;
    function) printf '1\n' ;;
    coproc)
      # Bash permits a coproc name only before a compound command. Without
      # one, the first word after coproc is the command and a later risky
      # word is only its argument, not the command whose risk is judged.
      named=0
      if (( ${#decoded[@]} > 2 )) && [[ ${decoded[1]} != -* && ${decoded[1]} != *=* ]]; then
        # The decoded view strips quotes, so a quoted opener would pass for
        # syntax. The third word of the quote-preserving view keeps its
        # quotes (and its \002-marked quoted whitespace), so only an actual
        # compound opener or keyword stands here as a coproc name boundary.
        structural_line=$(__lmline_split_pipeline "$structural_source" 2)
        structural_line=${structural_line%%$'\n'*}
        IFS=$' \t' read -r -a structural_words <<<"$structural_line"
        case "${structural_words[2]:-}" in
          '{'|'('*|if|while|until|for|select|case|'[['*)
            named=1
            ;;
        esac
      fi
      (( named )) && printf '1\n' || printf '0\n'
      ;;
    '!'|busybox|builtin|command|doas|env|exec|ionice|nice|nohup|screen|script|setsid|stdbuf|strace|sudo|systemd-run|taskset|time|timeout|tmux|toybox|unshare|watch|xargs) printf '0\n' ;;
  esac
  return 0
}

# Whether a word names a program that runs another program.
__lmline_risk_is_runner() {
  [[ -n $(__lmline_risk_runner_operands "$1") ]]
}

__lmline_word_is_command_prefix() {
  local word=$1 file
  # A brace group's opener stands before the command the group runs. It is
  # shell structure, not a user-configurable command vocabulary.
  [[ $word == '{' ]] && return 0
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
  # Shell matching preserves locale-aware whitespace/letters without asking
  # awk/sed to decode possibly invalid multibyte input. Other bytes stay raw.
  local line prefix
  while IFS= builtin read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] || continue
    if [[ $line == '```'* && ${line#'```'} != *[![:alpha:]]* ]]; then continue; fi
    if [[ $line == [-*][[:space:]]* ]]; then
      line=${line:1}
      line=${line#"${line%%[![:space:]]*}"}
    fi
    prefix=${line%%[!0-9]*}
    if [[ -n $prefix && ${line#"$prefix"} == [.\)][[:space:]]* ]]; then
      line=${line#"$prefix"?}
      line=${line#"${line%%[![:space:]]*}"}
    fi
    line=${line#\`}
    line=${line%\`}
    [[ -z $line ]] || printf '%s\n' "$line" || return
  done
}

__lmline_filter_candidates() {
  # Drop NUL-bearing records before any byte rewrite: Bash variables
  # cannot hold NUL, so a clean $BASH -p child records NUL delimiters
  # with read -r -d "" without storing NUL. Each NUL taints only its
  # newline-delimited record: first/last newline splits discard that
  # record and emit all other bytes unchanged, including unterminated
  # finals and arbitrary bytes. NUL-free input is emitted directly.
  # Buffer the result so a scanner/child or downstream failure admits
  # nothing; raw NUL never enters a Bash variable.
  local result
  result=$(
    set -o pipefail
    "$BASH" -p -c '
      LC_ALL=C
      tainted=0
      chunk=""
      rest=""
      tail=""
      nl="
"
      process() {
        if [[ $chunk == *"$nl"* ]]; then
          if (( tainted )); then
            rest=${chunk#*"$nl"}
          else
            rest=$chunk
          fi
          if [[ $rest == *"$nl"* ]]; then
            tail=${rest##*"$nl"}
            builtin printf "%s" "${rest:0:${#rest}-${#tail}}" || exit 1
          else
            tail=$rest
          fi
          if (( is_last )); then
            if [[ -n $tail ]]; then
              builtin printf "%s\n" "$tail" || exit 1
            fi
          else
            tainted=1
          fi
        else
          if (( is_last )); then
            if (( ! tainted )) && [[ -n $chunk ]]; then
              builtin printf "%s\n" "$chunk" || exit 1
            fi
          else
            tainted=1
          fi
        fi
      }
      if IFS= builtin read -r -d "" chunk; then
        is_last=0
        process
        while IFS= builtin read -r -d "" chunk; do
          is_last=0
          process
        done
        is_last=1
        process
      else
        if [[ -n $chunk ]]; then
          builtin printf "%s" "$chunk" || exit 1
          if [[ $chunk != *"$nl" ]]; then
            builtin printf "\n" || exit 1
          fi
        fi
      fi
    ' |
      __lmline_normalize_candidate_line
  ) || return
  if [[ -n $result ]]; then
    printf '%s\n' "$result"
  fi
}

__lmline_candidate_truncated() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096} byte_len
  __lmline_clamp_int max_len 4096 0 1
  byte_len=$(LC_ALL=C printf '%s' "$cmd" | wc -c)
  (( byte_len > max_len ))
}

__lmline_truncate_bytes() {
  local LC_ALL=C
  local text=$1 max_len=$2 length index byte required=0
  text=${text:0:max_len}
  length=${#text}
  index=$((length - 1))
  # If the byte limit lands inside a UTF-8 sequence, omit that incomplete
  # trailing code point. Other bytes are preserved; the input is not decoded.
  while (( index >= 0 )); do
    printf -v byte '%d' "'${text:index:1}"
    (( byte >= 128 && byte <= 191 )) || break
    index=$((index - 1))
  done
  if (( index >= 0 )); then
    printf -v byte '%d' "'${text:index:1}"
    if (( byte >= 194 && byte <= 223 )); then required=1
    elif (( byte >= 224 && byte <= 239 )); then required=2
    elif (( byte >= 240 && byte <= 244 )); then required=3
    fi
    if (( required > 0 && length - index - 1 < required )); then
      text=${text:0:index}
    fi
  fi
  printf '%s' "$text"
}

__lmline_truncate_candidate() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096}
  __lmline_clamp_int max_len 4096 0 1
  __lmline_truncate_bytes "$cmd" "$max_len"
}

__lmline_truncated_comment_candidate() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096} prefix="# TRUNCATED: " prefix_len body_len
  __lmline_clamp_int max_len 4096 0 1
  prefix_len=$(LC_ALL=C printf '%s' "$prefix" | wc -c | tr -d ' ')
  body_len=$((max_len - prefix_len))
  (( body_len > 0 )) || { __lmline_truncate_candidate "$cmd"; return 0; }
  printf '%s' "$prefix"
  __lmline_truncate_bytes "$cmd" "$body_len"
}

# Match C1 and Unicode Bidi_Control codepoints, not ordinary UTF-8 bytes.
# Keep byte matching local so validation never changes the caller's locale.
__lmline_has_unsafe_unicode_control() {
  local LC_ALL=C
  [[ "$1" == *$'\302'[$'\200'-$'\237']* ||
     "$1" == *$'\330\234'* ||
     "$1" == *$'\342\200'[$'\216'-$'\217'$'\252'-$'\256']* ||
     "$1" == *$'\342\201'[$'\246'-$'\251']* ]]
}

__lmline_valid_candidates() {
  if [[ ${__LMLINE_VALIDATION_ISOLATED-} != 1 ]]; then
    __lmline_validation_run valid-candidates "$@"
    return
  fi
  local candidate reason
  while IFS= read -r candidate; do
    __lmline_has_unsafe_unicode_control "$candidate" && continue
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
  [[ $(__lmline_candidate_rejection_reason "$@") == ok ]]
}

__lmline_candidate_rejection_reason() {
  if [[ ${__LMLINE_VALIDATION_ISOLATED-} != 1 ]]; then
    __lmline_validation_run candidate "$@"
    return
  fi
  local cmd=$1 mode=${2:-} shell=${3:-bash} syntax_status=0
  [[ -n "$cmd" ]] || return 1
  [[ "$cmd" != *$'\n'* ]] || { printf 'multiline'; return 0; }
  [[ "$cmd" != *$'\r'* ]] || { printf 'carriage-return'; return 0; }
  [[ ! "$cmd" =~ ^[[:space:]]*\`\`\`[[:alpha:]]*[[:space:]]*$ ]] || { printf 'markdown-fence'; return 0; }
  if __lmline_has_unsafe_unicode_control "$cmd" || [[ "$cmd" == *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037'$'\177']* ]]; then
    printf 'control-character'
    return 0
  fi
  if [[ "$mode" == fix ]]; then
    [[ "$cmd" != "## "* && "$cmd" != "### "* ]] || { printf 'fix-heading'; return 0; }
    [[ "$cmd" != exit_status=* ]] || { printf 'fix-status'; return 0; }
  fi
  [[ "$cmd" == "# TRUNCATED: "* || "$cmd" == "# REVIEW REQUIRED: "* ]] && { printf 'ok'; return 0; }
  if [[ "$shell" == zsh ]]; then
    __lmline_zsh_syntax_probe "$cmd" || syntax_status=$?
    case $syntax_status in
      0) ;;
      1) printf 'shell-syntax'; return 0 ;;
      *) printf 'shell-validator-unavailable'; return 0 ;;
    esac
  else
    "$BASH" -p -n -c "$cmd" >/dev/null 2>&1 || { printf 'shell-syntax'; return 0; }
  fi
  __lmline_reject_env_only_pipeline "$cmd" "$shell" || { printf 'env-only-command-segment'; return 0; }
  __lmline_reject_directory_file_operands "$cmd" || { printf 'directory-file-operand'; return 0; }
  __lmline_validate_commands_available "$cmd" "$shell" || { printf 'command-not-found'; return 0; }
  printf 'ok'
}

__lmline_backtick_content() {
  local cmd=$1 start=$2 close=$(( $2 + 1 ))
  while (( close < ${#cmd} )); do
    [[ ${cmd:close:1} == '`' && ${cmd:close-1:1} != $'\\' ]] && break
    close=$((close + 1))
  done
  printf '%s' "${cmd:start+1:close-start-1}"
}

__lmline_backtick_risky() {
  local cmd=$1 start=$2 emit=$3 require_special=$4 content
  content=$(__lmline_backtick_content "$cmd" "$start")
  if (( require_special )) && [[ "$content" != *[[:space:]\;\&\|\(\)\`]* && "$content" != *'${IFS}'* && "$content" != *'$IFS'* ]]; then
    printf '0'
  elif [[ "$content" == *'|'* || "$content" == *';'* || "$content" == *'&'* || "$content" == *'$('* || "$content" == *'<('* || "$content" == *'\`'* ]]; then
    printf '1'
  elif (( emit )) && [[ "$content" != *'`'* ]] && __lmline_risk_recursive_remove "$content"; then
    printf '1'
  else
    printf '0'
  fi
}

__lmline_split_pipeline() {
  local cmd=$1 keep_quoted=${2:-0} extra_seps=${3:-} syntax_shell=${4:-bash} split_mode=${5:-all} emit_boundary=${6:-1}
  local structural_mode=0 subst_marker=0
  [[ $split_mode == structural-substitution || $split_mode == structural-substitution-marker ]] && structural_mode=1
  [[ $split_mode == structural-substitution-marker ]] && subst_marker=1
  local stripped="" i ch next quote="" prev="" dq_subst_depth=0 dq_opener=0 dq_backslash_odd=0 dq_escaped_dollar=0 bt_subst_depth=0 bt_exposed=0 bt_quote_return=0 bt_risky=0 bt_bs_run=0 bt_escaped_sep=0 bt_escaped_bt=0 dq_backtick_depth=0 zsh_glob_qualifier_depth=0 zsh_qualifier_just_closed=0 prior_zsh_qualifier_close
  local subst_boundary=$'\n'
  local quote_was_exposed=0
  local dq_subst_quote=0 dq_subst_escape=0 dq_subst_dquote=0 dq_quote_stack=""
  (( emit_boundary )) || subst_boundary=
  # The cwd-pipeline view is opt-in, only after the caller proves the input
  # is a flat simple list. All other callers retain their existing view.
  for ((i = 0; i < ${#cmd}; i++)); do
    ch=${cmd:i:1}
    next=${cmd:i+1:1}
    prior_zsh_qualifier_close=$zsh_qualifier_just_closed
    zsh_qualifier_just_closed=0
    if [[ -n "$quote" ]]; then
      # Backticks open a command substitution for structural checks, so its
      # content and operators are read as commands rather than as one word.
      if (( structural_mode )) && [[ "$quote" == '`' ]] && (( bt_exposed )); then
        if [[ "$ch" == "\\" ]]; then
          # Backslashes are kept through backtick dequoting except when they
          # pair, so a separator is escaped by one or two of them and a
          # backtick is escaped by an odd run.
          bt_bs_run=$(( (bt_bs_run + 1) % 4 ))
          (( keep_quoted )) && stripped+=$ch
          prev=$ch
          continue
        fi
        bt_escaped_sep=$(( bt_bs_run == 1 || bt_bs_run == 2 ))
        bt_escaped_bt=$(( bt_bs_run == 1 || bt_bs_run == 3 ))
        bt_bs_run=0
        if [[ "$ch" == "'" || "$ch" == '"' ]] && (( ! bt_escaped_sep )); then
          quote=$ch
          bt_quote_return=1
          (( keep_quoted )) && stripped+=$ch
          prev=$ch
          continue
        fi
        if [[ "$ch" == '(' && ( "$prev" == '$' || "$prev" == '<' ) ]]; then
          bt_subst_depth=$((bt_subst_depth + 1))
          if [[ -n "$subst_boundary" ]]; then
            stripped+=$subst_boundary
          else
            (( keep_quoted )) && stripped+=$ch
          fi
          prev=$ch
          continue
        fi
        if (( bt_subst_depth > 0 )) && [[ "$ch" == ')' ]]; then
          bt_subst_depth=$((bt_subst_depth - 1))
          if [[ -n "$subst_boundary" ]]; then
            stripped+=$subst_boundary
          else
            (( keep_quoted )) && stripped+=$ch
          fi
          prev=$ch
          continue
        fi
        if [[ "$ch" == '`' ]] && (( bt_escaped_bt )); then
          # An escaped backtick inside backticks becomes a real backtick
          # when the outer command string is parsed, so it opens or closes
          # a nested command substitution.
          if [[ -n "$subst_boundary" ]]; then
            stripped+=$subst_boundary
          else
            (( keep_quoted )) && stripped+=$ch
          fi
          prev=$ch
          continue
        fi
        if [[ "$ch" == '`' ]] && (( ! bt_escaped_bt )); then
          quote=
          quote_was_exposed=$bt_exposed
          bt_exposed=0
          if (( emit_boundary )) && (( quote_was_exposed )); then
            stripped+=$'\n'
          elif (( quote_was_exposed )); then
            stripped+=' '
          else
            (( keep_quoted )) && stripped+=$ch
          fi
          prev=$ch
          continue
        fi
        if [[ "$ch" == '|' || "$ch" == ';' || "$ch" == '&' ]] && (( ! bt_escaped_sep )); then
          stripped+=$'\n'
          prev=$ch
          continue
        fi
      fi
      # Double quotes do not stop a command substitution from running. Open
      # its content as its own segment for structural checks; single quotes
      # still keep the same text inert.
      if (( structural_mode )) && [[ "$quote" == '"' ]]; then
        # Inside a command substitution the body is shell syntax again:
        # single quotes and backslashes make substitution openers literal.
        if (( dq_subst_depth > 0 )); then
          if (( dq_subst_quote )); then
            [[ "$ch" == "'" ]] && dq_subst_quote=0
            (( keep_quoted )) && stripped+=$ch
            prev=$ch
            continue
          fi
          if (( dq_subst_escape )); then
            dq_subst_escape=0
            (( keep_quoted )) && stripped+=$ch
            prev=$ch
            continue
          fi
          if [[ "$ch" == $'\\' ]]; then
            dq_subst_escape=1
            (( keep_quoted )) && stripped+=$ch
            prev=$ch
            continue
          fi
          if [[ "$ch" == '"' ]]; then
            (( dq_subst_dquote = 1 - dq_subst_dquote ))
            (( keep_quoted )) && stripped+=$ch
            prev=$ch
            continue
          fi
          if [[ "$ch" == "'" ]] && (( ! dq_subst_dquote )); then
            dq_subst_quote=1
            (( keep_quoted )) && stripped+=$ch
            prev=$ch
            continue
          fi
        fi
        if [[ "$ch" == '`' ]]; then
          if (( dq_backtick_depth > 0 )); then
            dq_backtick_depth=$((dq_backtick_depth - 1))
            stripped+=' '
          else
            bt_risky=$(__lmline_backtick_risky "$cmd" "$i" "$emit_boundary" 0)
            if (( bt_risky )); then
              dq_backtick_depth=$((dq_backtick_depth + 1))
              if [[ -n "$subst_boundary" ]]; then
                (( subst_marker )) && stripped+='$'
                stripped+=$subst_boundary
              else
                (( keep_quoted )) && stripped+=$ch
              fi
            else
              (( keep_quoted )) && stripped+=$ch
            fi
          fi
          prev=$ch
          continue
        fi
        dq_opener=0
        if [[ "$ch" == '(' && "$prev" == '$' ]] && (( ! dq_escaped_dollar )); then
          dq_opener=1
        elif [[ "$ch" == '(' && "$prev" == '<' ]] && (( dq_subst_depth > 0 )) && (( ! dq_subst_dquote )); then
          dq_opener=1
        fi
        if (( dq_opener )); then
          dq_quote_stack+="${dq_subst_dquote}"
          dq_subst_dquote=0
          dq_subst_depth=$((dq_subst_depth + 1))
          dq_escaped_dollar=0
          if [[ -n "$extra_seps" && "$extra_seps" == *'('* ]]; then
            stripped+=$'\n'
          else
            (( keep_quoted )) && stripped+=$ch
          fi
          prev=$ch
          continue
        fi
        if (( dq_subst_depth > 0 )) && [[ "$ch" == ')' ]]; then
          dq_subst_depth=$((dq_subst_depth - 1))
          dq_escaped_dollar=0
          dq_subst_quote=0
          dq_subst_escape=0
          if [[ -n "$dq_quote_stack" ]]; then
            dq_subst_dquote=${dq_quote_stack:${#dq_quote_stack}-1}
            dq_quote_stack=${dq_quote_stack%?}
          else
            dq_subst_dquote=0
          fi
          if [[ -n "$extra_seps" && "$extra_seps" == *'('* ]]; then
            # Restored inside double quotes, the suffix is data in the
            # enclosing word: no command boundary, but keep a word break so
            # a literal separator cannot glue a remove to the substitution.
            if (( dq_subst_dquote )); then
              (( keep_quoted )) && stripped+=$ch
              stripped+=' '
            else
              stripped+=$'\n'
            fi
          else
            (( keep_quoted )) && stripped+=$ch
          fi
          prev=$ch
          continue
        fi
        if (( dq_subst_depth > 0 || dq_backtick_depth > 0 )) && (( ! dq_subst_dquote )) && [[ "$ch" == '|' || "$ch" == ';' || "$ch" == '&' ]]; then
          dq_escaped_dollar=0
          stripped+=$'\n'
          prev=$ch
          continue
        fi
      fi
      if (( structural_mode )) && [[ "$quote" == '"' ]]; then
        if [[ "$ch" == $'\\' ]]; then
          (( dq_backslash_odd = 1 - dq_backslash_odd ))
        else
          if [[ "$ch" == '$' ]] && (( dq_backslash_odd )); then
            dq_escaped_dollar=1
          else
            dq_escaped_dollar=0
          fi
          dq_backslash_odd=0
        fi
      fi
      if [[ "$quote" == '"' && "$ch" == "\\" && "$prev" != "\\" ]]; then
        prev=$ch
        (( keep_quoted )) && stripped+=$ch
        continue
      fi
      # A backslash is literal in ordinary single quotes, so it cannot
      # keep a closing quote open (the `'\''` spelling is plain data).
      # Only double quotes and backticks let it escape the delimiter.
      if [[ "$ch" == "$quote" ]] && [[ "$quote" == "'" || "$prev" != "\\" ]]; then
        if (( bt_quote_return )); then
          quote='`'
          bt_quote_return=0
          bt_bs_run=0
        else
          quote=
        fi
      fi
      # Availability's opt-in view keeps a quoted word in one whitespace
      # token. The marker is opaque to literal decoding, not shell syntax.
      if (( keep_quoted == 2 )) && [[ "$ch" == [[:space:]] ]]; then
        stripped+=$'\002'
      else
        (( keep_quoted )) && stripped+=$ch
      fi
      prev=$ch
      continue
    fi
    # A backslash outside quotes makes the next character data. Without
    # this, an escaped quote would open a false quoted word and hide the
    # separator that follows it (echo a\';rm -rf /).
    if [[ $ch == "\\" && $split_mode != command-prefix && $split_mode != cwd-pipeline ]] && (( i + 1 < ${#cmd} )); then
      if (( keep_quoted == 2 )) && [[ ${cmd:i+1:1} == [[:space:]] ]]; then
        stripped+=$'\002'
      elif (( keep_quoted )); then
        stripped+="$ch${cmd:i+1:1}"
      fi
      i=$((i + 1))
      prev=${cmd:i:1}
      continue
    fi
    # Prefix inspection needs opaque quoted/escaped words, not their data:
    # dropping a quoted command would expose its arguments as a false prefix.
    # Keep this view local; other splitter callers retain their existing copy.
    if [[ "$split_mode" == command-prefix || "$split_mode" == cwd-pipeline ]]; then
      if [[ "$ch" == '#' && ( -z "$prev" || "$prev" == [[:space:]\;\&\|\(\)] ) ]]; then
        while (( i < ${#cmd} )) && [[ ${cmd:i:1} != $'\n' ]]; do
          i=$((i + 1))
        done
        stripped+=$'\n'
        prev=$'\n'
        continue
      fi
      if [[ "$ch" == "\\" ]]; then
        stripped+=$'\001'
        i=$((i + 1))
        prev=$'\001'
        continue
      fi
    fi
    case "$ch" in
      "'"|'"'|'`')
        quote=$ch
        [[ "$split_mode" != command-prefix && "$split_mode" != cwd-pipeline ]] || stripped+=$'\001'
        if (( structural_mode )) && [[ "$ch" == '`' ]]; then
          bt_risky=$(__lmline_backtick_risky "$cmd" "$i" "$emit_boundary" 1)
          if (( bt_risky )); then
            bt_exposed=1
            bt_bs_run=0
            if [[ -n "$subst_boundary" ]]; then
              (( subst_marker )) && stripped+='$'
              stripped+=$subst_boundary
            else
              (( keep_quoted )) && stripped+=$ch
            fi
          else
            (( keep_quoted )) && stripped+=$ch
          fi
        else
          (( keep_quoted )) && stripped+=$ch
        fi
        ;;
      '|'|';'|'&')
        # Inside an open zsh glob qualifier a separator is part of the word
        # (*(e:echo hi|cat:) is one glob), so it does not split there.
        if [[ "$syntax_shell" == zsh ]] && (( zsh_glob_qualifier_depth > 0 )); then
          stripped+=$ch
        elif [[ "$split_mode" == cwd-pipeline && "$ch" == '|' ]]; then
          # Suffix the member, rather than emitting a standalone boundary:
          # the consumer must know it is non-final before inspecting it.
          stripped+=$'\003\n'
        elif [[ "$split_mode" == env-pipeline ]]; then
          case "$ch" in
            '|')
              if [[ "$next" == '|' ]]; then
                # || is a list operator, not a pipeline member boundary.
                stripped+=$'\001'
                i=$((i + 1))
              else
                # |& is still a pipeline operator.
                stripped+=$'\n'
                [[ "$next" == '&' ]] && i=$((i + 1))
              fi
              ;;
            ';') stripped+=$'\001' ;;
            '&')
              if [[ "$prev" == '>' || "$next" == '>' ]]; then
                # Preserve redirections such as >&2 and &>file.
                stripped+=$ch
              else
                stripped+=$'\001'
                [[ "$next" == '&' ]] && i=$((i + 1))
              fi
              ;;
          esac
        elif [[ "$ch" == '&' && ( "$next" == '>' || "$prev" == '>' || "$prev" == '<' ) ]] ||
             [[ "$ch" == '|' && "$prev" == '>' ]]; then
          # &>, >&, <&, >| and their descriptor-prefixed forms are one
          # redirect operator, not a command boundary: the redirect consumer
          # needs to see its target so a following here-string can still be
          # judged as shell input. A bare & after a command still splits.
          stripped+=$ch
        else
          stripped+=$'\n'
        fi
        ;;
      *)
        if [[ -n "$extra_seps" && "$extra_seps" == *"$ch"* ]]; then
          # A zsh glob qualifier is attached to a word; keep the qualifier
          # pair together, including stacked qualifiers like *(N)(.).
          if [[ "$syntax_shell" == zsh && "$ch" == '(' ]]; then
            if (( zsh_glob_qualifier_depth > 0 )); then
              zsh_glob_qualifier_depth=$((zsh_glob_qualifier_depth + 1))
              stripped+=$ch
            elif (( prior_zsh_qualifier_close )); then
              zsh_glob_qualifier_depth=1
              stripped+=$ch
            else
              case "$prev" in
                ''|[[:space:]]|'|'|';'|'&'|'('|'$'|'<'|'>'|'=')
                  stripped+=$'\n'
                  ;;
                *)
                  zsh_glob_qualifier_depth=1
                  stripped+=$ch
                  ;;
              esac
            fi
          elif [[ "$syntax_shell" == zsh && "$ch" == ')' ]] && (( zsh_glob_qualifier_depth > 0 )); then
            zsh_glob_qualifier_depth=$((zsh_glob_qualifier_depth - 1))
            stripped+=$ch
            if (( zsh_glob_qualifier_depth == 0 )); then
              zsh_qualifier_just_closed=1
            fi
          else
            stripped+=$'\n'
          fi
        else
          stripped+=$ch
        fi
        ;;
    esac
    prev=$ch
  done
  printf '%s\n' "$stripped"
}

__lmline_segment_is_assignment_only() {
  local segment=$1 token saw_assignment=0
  local -a words
  read -r -a words <<<"$segment"
  for token in "${words[@]}"; do
    case "$token" in
      [A-Za-z_]*=*) saw_assignment=1 ;;
      *) return 1 ;;
    esac
  done
  (( saw_assignment == 1 ))
}

__lmline_reject_env_only_pipeline() {
  local cmd=$1 syntax_shell=${2:-bash} stripped segment rest list_part i last_list_part has_command
  local -a pipeline_segments list_segments
  # Preserve quoted command words (including PATH-prefixed literal paths);
  # mask their whitespace so quoted assignment values remain single tokens.
  stripped=$(__lmline_split_pipeline "$cmd" 2 "" "$syntax_shell" env-pipeline)

  while IFS= read -r segment; do
    pipeline_segments+=("$segment")
  done <<<"$stripped"
  if ((${#pipeline_segments[@]} == 1)); then
    rest=${pipeline_segments[0]}
    has_command=0
    while [[ "$rest" == *$'\001'* ]]; do
      list_part=${rest%%$'\001'*}
      __lmline_segment_is_assignment_only "$list_part" || has_command=1
      rest=${rest#*$'\001'}
    done
    __lmline_segment_is_assignment_only "$rest" || has_command=1
    ((has_command == 1)) || return 1
    return 0
  fi

  for ((i = 0; i < ${#pipeline_segments[@]}; i++)); do
    rest=${pipeline_segments[i]}
    list_segments=()
    while [[ "$rest" == *$'\001'* ]]; do
      list_part=${rest%%$'\001'*}
      list_segments+=("$list_part")
      rest=${rest#*$'\001'}
    done
    list_segments+=("$rest")
    last_list_part=${list_segments[$((${#list_segments[@]} - 1))]}

    # Only the command immediately next to a pipe belongs to that pipeline.
    # Earlier/later list commands may be assignment-only statements.
    if ((i > 0)) && __lmline_segment_is_assignment_only "${list_segments[0]}"; then
      return 1
    fi
    if ((i < ${#pipeline_segments[@]} - 1)) && __lmline_segment_is_assignment_only "$last_list_part"; then
      return 1
    fi
  done
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
  local str=$1 out="" pre rest inner ch i j esc decoded qmark
  [[ $str == *"\$'"* ]] || { printf '%s' "$str"; return 0; }
  printf -v qmark '\035'
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
      if [[ $ch == "\\" && ${rest:i+1:1} == "'" ]]; then
        # In $'...', a backslash before an apostrophe decodes to a live
        # apostrophe, not a literal backslash-quote pair. Mark it at
        # collection time so it cannot end up as inert data after %b.
        inner+="$qmark"
        i=$((i + 1))
        continue
      fi
      if [[ $ch == "\\\\" ]]; then
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
    # A decoded newline would be read as an alternative boundary by the
    # classifier. Show it as a command separator inside the quoted word: a
    # shell that receives the word still runs the commands it separates.
    decoded=${decoded//$'\n'/';'}
    # Keep the decoded text one quoted word: operators inside $'...' are
    # literal data, not commands. A decoded single quote is held by an
    # internal marker that cannot occur in a validated candidate: it stays
    # inert for the structural checks, and canonicalization drops it so a
    # quote-delimited command name remains recognizable. Both octal-decoded
    # quotes and backslash-escaped apostrophes use this marker; they are live
    # quotes in the script a shell runs.
    decoded=${decoded//\'/$qmark}
    out+="$pre'$decoded'"
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
    -e 's#\|[[:space:]]*/[^[:space:]|;()&]*/#| #g' | tr -d '\035'
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
    [[ $rest == *'}'* ]] || break
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
          # A group without a comma or range is literal, not an expansion:
          # keep its braces so structural checks can still see a compound
          # command. The pattern view strips them below as before.
          if __lmline_brace_at_word_boundary "${pre: -1}" &&
            __lmline_brace_at_word_boundary "${post:0:1}"; then
            next+="${pre}${ob}${inner}${cb}${post}"$'\n'
          else
            next+="${pre} ${inner} ${post}"$'\n'
          fi
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

# Structural pipe-to-shell recognition for risk matching only (not execution).
# The resulting level is configuration (LMLINE_RISK_PIPED_SHELL_LEVEL,
# default high); see __lmline_risk_match for precedence.
# Any non-first pipeline segment led by a wrapper (command/builtin/exec/env/
# time/sudo/nohup/nice/!) or a shell itself, where any later word (after
# stripping assignments, quoting and absolute paths) is an interactive shell,
# executes piped stdin as code. Scanning every word after the wrapper gate
# replaces per-flag value tables (which grow without bound: -a/-u/-g/-n, then
# -C/-S/--unset/--chdir/--argv0/--adjustment/...) and closes short and long
# separate-value forms at once. Only the sh family is judged here: piping a
# local file to python and similar interpreters is ordinary use and stays low
# unless a downloader-specific pattern matches. The leading-wrapper gate keeps
# benign '| grep sh' / '| ssh user@host' / '| shuf' low; a contrived wrapper
# call whose option value is literally named sh (exec -a sh echo) scores high,
# which is the fail-closed direction.
__lmline_risk_piped_shell() {
  local cmd=$1 stripped segment token word base cmd_index
  local -a words subs
  stripped=$(__lmline_split_pipeline "$cmd" 1 "" bash structural-substitution 0)
  local idx=0
  while IFS= read -r segment || [[ -n $segment ]]; do
    idx=$((idx + 1))
    (( idx > 1 )) || continue
    [[ -n "${segment//[[:space:]()]/}" ]] || continue
    read -r -a words <<<"$segment" || continue
    subs=()
    for token in "${words[@]}"; do
      word=$(__lmline_unquote_simple_word "$token")
      word=${word//[()]/}
      [[ -n "$word" ]] || continue
      case "$word" in
        [A-Za-z_]*=*) continue ;;
      esac
      word=${word#\`}; word=${word%\`}
      [[ -n "$word" ]] || continue
      subs+=("$word")
    done
    ((${#subs[@]} > 0)) || continue
    # The shell the piped input reaches is the command the segment runs: a
    # program that runs another program runs the command it is given, so the
    # shell it runs is the shell the pipe reaches. A shell-named word that is
    # only an argument of that command does not reach the pipe.
    cmd_index=$(__lmline_risk_segment_command_index "${subs[@]}") || continue
    word=${subs[cmd_index]}
    if __lmline_risk_word_runs_shell "$word"; then
      return 0
    fi
  done <<<"$stripped"
  return 1
}

# Detect potentially active default-character interactive history references on
# the original text, before quote removal/ANSI-C decoding. This is a lexical
# check, not a history parser: it never reads/expands history or edits text.
# Ordinary and ANSI-C single quotes inhibit references; double quotes do not.
# A backslash immediately before ! inhibits that character in both shells,
# even when another backslash precedes it. A later ! can still start a
# reference (\!!:p). Bare ! before whitespace, =, or end of input is literal;
# ! before a closing double quote is not a reference (Bash literal, zsh
# history-disable syntax). Other unescaped ! prefixes are potentially active,
# including !!, !n, !-n, !word, !?text?, !#, word selectors and zsh's !{...}.
# Assumes conventional Bash/zsh history settings, not custom histchars,
# disabled expansion, or Bash POSIX mode. Quick ^ substitution and full
# parsing of nested shell constructs are deliberately outside scope.
__lmline_risk_history_expansion() {
  local cmd=$1 quote="" ansi=0 i ch next
  [[ $cmd == *'!'* ]] || return 1
  for ((i = 0; i < ${#cmd}; i++)); do
    ch=${cmd:i:1}
    next=${cmd:i+1:1}
    if [[ $quote == "'" ]]; then
      if (( ansi )) && [[ $ch == "\\" ]]; then
        i=$((i + 1))
      elif [[ $ch == "'" ]]; then
        quote=""
        ansi=0
      fi
      continue
    fi
    case "$ch" in
      "\\") i=$((i + 1)) ;;
      '$')
        if [[ -z $quote && $next == "'" ]]; then
          quote="'"
          ansi=1
          i=$((i + 1))
        fi
        ;;
      "'") [[ -n $quote ]] || quote="'" ;;
      '"')
        if [[ -z $quote ]]; then quote='"'; else quote=""; fi
        ;;
      '!')
        (( i == 0 )) || [[ ${cmd:i-1:1} != "\\" ]] || continue
        case "$next" in
          ""|[[:space:]]|'=') continue ;;
          '"') [[ $quote == '"' ]] && continue ;;
        esac
        return 0
        ;;
    esac
  done
  return 1
}

# Structural risk levels are configuration, not hardcoded policy. Each
# defaults to its protective value (piped shell/history high, the two
# unresolved fallbacks medium); an unset, empty, or unknown value falls back to its
# default so the check fails closed.
__lmline_risk_structural_level() {
  local value=${1-} default=${2:-medium}
  case "$value" in
    high|medium|low) printf '%s\n' "$value" ;;
    *) printf '%s\n' "$default" ;;
  esac
}

__lmline_risk_level_rank() {
  case "${1-}" in
    high) printf '3\n' ;;
    medium) printf '2\n' ;;
    low) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

# Split a command into the words the policy judges: quotes group words and
# are removed, and a backslash escapes the next character. The words are
# data and are never executed.
__lmline_risk_split_words() {
  local str=$1 keep_backticks=${2:-0} word="" ch quote="" i n
  n=${#str}
  for ((i = 0; i < n; i++)); do
    ch=${str:i:1}
    if [[ -n "$quote" ]]; then
      if [[ "$quote" == '"' && "$ch" == "\\" ]]; then
        i=$((i + 1))
        word+=${str:i:1}
        continue
      fi
      if [[ "$ch" == "$quote" ]]; then
        if (( keep_backticks )) && [[ "$ch" == '`' ]]; then
          word+=$ch
        fi
        quote=""
        continue
      fi
      word+=$ch
      continue
    fi
    case "$ch" in
      "'"|'"'|'`')
        quote=$ch
        if (( keep_backticks )) && [[ "$ch" == '`' ]]; then
          word+=$ch
        fi
        ;;
      "\\")
        i=$((i + 1))
        word+=${str:i:1}
        ;;
      ' '|$'\t')
        if [[ -n "$word" ]]; then
          printf '%s\n' "$word"
          word=""
        fi
        ;;
      *) word+=$ch ;;
    esac
  done
  if [[ -n "$word" ]]; then
    printf '%s\n' "$word"
  fi
  return 0
}

# The flags rm writes: a cluster it owns may carry the recursive flag in any
# spelling, so the cluster is read as rm's own rather than filtered by a
# letter list that rm itself does not keep. The end of the options ends the
# scan; an operand does not, because rm reads its options after an operand
# too.
__lmline_risk_remove_is_recursive() {
  local word cluster
  for word in "$@"; do
    case "$word" in
      --) return 1 ;;
      --recursive) return 0 ;;
      --*) ;;
      -?*)
        cluster=${word#-}
        case "$cluster" in
          *[rR]*) return 0 ;;
        esac
        ;;
      *) ;;
    esac
  done
  return 1
}

# The first shell word a candidate word stands for. Quoting is removed and
# expansions are spaced, so a spelling that hides a command is read as the
# words it runs. The command-position predicates share this parsing; each
# keeps its own policy for what the first word means.
__lmline_risk_canonical_first_word() {
  local canonical
  local -a canon=()
  canonical=$(__lmline_canonicalize_for_risk <<<"$1") || true
  [[ -n $canonical ]] || return 1
  read -r -a canon <<<"$canonical" || true
  ((${#canon[@]} > 0)) || return 1
  printf '%s' "${canon[0]}"
}

# Whether a word runs a shell.
__lmline_risk_word_runs_shell() {
  local first
  first=$(__lmline_risk_canonical_first_word "$1") || return 1
  __lmline_word_is_shell "${first##*/}"
}

# Whether a word invokes the shell's source or dot builtin. These read and
# execute a script file, but are not external shell programs, so they are kept
# out of the shared shell-word list used by other risk checks.
__lmline_risk_word_sources_script() {
  local first
  first=$(__lmline_risk_canonical_first_word "$1") || return 1
  [[ $first == source || $first == . ]]
}

# Whether a word stands for the remove command. The word is read as the
# words it runs, with the quoting removed and the expansions spaced, so a
# spelling that hides the command (rm${IFS}-rf, `echo rm`) is read as the
# words it runs.
__lmline_risk_word_is_remove_command() {
  local canonical index
  local -a canon=()
  canonical=$(__lmline_canonicalize_for_risk <<<"$1")
  [[ -n $canonical ]] || return 1
  read -r -a canon <<<"$canonical" || true
  for (( index = 0; index < ${#canon[@]}; index++ )); do
    if [[ "${canon[index]##*/}" == rm ]]; then
      return 0
    fi
  done
  return 1
}

# An option whose value is a path, named by the runner that owns it. Option
# meaning is runner-specific: env -C takes a directory while setsid -f is a
# boolean. A path-like word after any other option is the command the runner
# runs, not that option's value.
__lmline_risk_option_takes_path_value() {
  local -a decoded=()
  mapfile -t decoded < <(__lmline_risk_split_words "$1")
  local runner=${decoded[0]:-$1}
  local option=${2##*/}
  case ${runner##*/} in
    env)
      case $option in
        -C|--chdir) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# The command a program that runs another program runs: the first word that
# is not one of the program's own options, not the value one of those
# options takes, and not an operand the program names for itself. A remove
# or a shell in that position is the command the program runs, whatever the
# option before it names.
__lmline_risk_carried_command_index() {
  __lmline_risk_carried_command_index_with "" "$@"
}

# Keep the quote-preserving source aligned with a word slice: when the index
# helper steps past a leading wrapper, the coproc check must see the same first
# word as the decoded operands it is judging.
__lmline_risk_structural_source_from_word() {
  local source_text=$1 skip=$2
  local -a source_words=()
  (( skip > 0 )) || { printf '%s' "$source_text"; return 0; }
  [[ -n $source_text ]] || { printf '%s' ""; return 0; }
  IFS=$' \t' read -r -a source_words <<<"$(__lmline_split_pipeline "$source_text" 2)"
  printf '%s' "${source_words[*]:skip}"
}

# The quote-preserving source is passed separately: decoded words alone cannot
# tell a compound opener from an argument spelled like one.
__lmline_risk_carried_command_index_with() {
  local structural_source_text=$1
  shift
  local -a words=("$@")
  local index word expect_value=0 last_option=""
  local operands_left
  operands_left=$(__lmline_risk_runner_operands "${words[*]}" "$structural_source_text")
  for (( index = 1; index < ${#words[@]}; index++ )); do
    word=${words[index]}
    [[ "$word" == *=* ]] && continue
    if [[ "$word" == -* ]]; then
      last_option=$word
      expect_value=1
      continue
    fi
    if __lmline_risk_word_is_remove_command "$word" || __lmline_risk_word_runs_shell "$word"; then
      printf '%s\n' "$index"
      return 0
    fi
    if (( expect_value )); then
      expect_value=0
      if [[ "$word" != */* ]] ||
        __lmline_risk_option_takes_path_value "${words[0]}" "$last_option"; then
        continue
      fi
    fi
    case "$word" in
      [0-9]*) continue ;;
    esac
    if (( operands_left > 0 )); then
      # An operand the program names for itself, such as the user su runs
      # as, stands between the program and the command it runs.
      operands_left=0
      continue
    fi
    printf '%s\n' "$index"
    return 0
  done
  return 1
}

# The command a segment runs, as the index of its word. A program that runs
# another program hands the command it runs to the next program, so the chain
# is followed to the command that runs.
__lmline_risk_segment_command_index() {
  __lmline_risk_segment_command_index_with "" "$@"
}

__lmline_risk_segment_command_index_with() {
  local structural_source_text=$1
  shift
  local -a words=("$@")
  local index=0 word base cmd_index sliced_source
  while :; do
    # The command word of the simple command: the first word that is not an
    # assignment and not an option. A word that can stand before the command
    # name is stepped over, but a program that runs another program is the
    # command itself.
    while (( index < ${#words[@]} )); do
      word=${words[index]}
      if [[ "$word" == *=* || "$word" == -* ]]; then
        index=$((index + 1))
        continue
      fi
      if __lmline_word_is_command_prefix "$word" && ! __lmline_risk_is_runner "$word"; then
        index=$((index + 1))
        continue
      fi
      break
    done
    (( index < ${#words[@]} )) || return 1
    word=${words[index]}
    base=${word##*/}
    if __lmline_word_is_shell "$base"; then
      printf '%s\n' "$index"
      return 0
    fi
    if __lmline_risk_is_runner "$base"; then
      sliced_source=$(__lmline_risk_structural_source_from_word "$structural_source_text" "$index")
      cmd_index=$(__lmline_risk_carried_command_index_with "$sliced_source" "${words[@]:index}") || return 1
      index=$((index + cmd_index))
      continue
    fi
    printf '%s\n' "$index"
    return 0
  done
}

# Whether a word stands for the remove command and the flags it carries.
# The word is read as the words it runs, with the quoting removed and the
# expansions spaced, so a spelling that hides the command (rm${IFS}-rf,
# `echo rm`) is read as the words it runs; the flags are the words the
# removal writes after its own name, and the words that follow it.
__lmline_risk_remove_word_is_recursive() {
  local word=$1
  shift
  local canonical index after
  local -a canon=() flags=()
  canonical=$(__lmline_canonicalize_for_risk <<<"$word")
  if [[ -n $canonical ]]; then
    read -r -a canon <<<"$canonical" || true
  fi
  for (( index = 0; index < ${#canon[@]}; index++ )); do
    if [[ "${canon[index]##*/}" == rm ]]; then
      # The words the removal writes after its own name, and the words that
      # follow it in the segment.
      for (( after = index + 1; after < ${#canon[@]}; after++ )); do
        flags+=("${canon[after]}")
      done
      flags+=("$@")
      (( ${#flags[@]} > 0 )) || return 1
      __lmline_risk_remove_is_recursive "${flags[@]}" && return 0
      return 1
    fi
  done
  return 1
}

# Whether the command string a shell command word runs removes recursively.
# The string is the word after the -c option, which may be glued to the
# option. The shell's own options stand between the shell and that string,
# so the search continues past them; the value of an option that takes one
# belongs to the shell as well, and a word that is neither is the script the
# shell runs, which ends the search.
# The command strings a shell runs through -c. A long option takes a value but
# is never -c; a clustered -c carries the rest of its word and following words.
# The marker keeps a decoded apostrophe inert while the outer word is scanned;
# in the script a shell runs it is a real quote, so restore it for the inner
# scan.
__lmline_risk_shell_c_command_strings() {
  local word cluster carried index count=$# expect_value=0 qmark apostrophe
  printf -v qmark '\035'
  printf -v apostrophe '\047'
  local -a shell_args=("$@")
  for (( index = 0; index < count; index++ )); do
    word=${shell_args[index]}
    if [[ "$word" == -* ]]; then
      if [[ "$word" == --* ]]; then
        expect_value=1
        continue
      fi
      cluster=${word#-}
      case "$cluster" in
        *c*)
          carried=${cluster#*c}
          if [[ -n $carried ]]; then
            while (( index + 1 < count )); do
              index=$((index + 1))
              carried+=" ${shell_args[index]}"
            done
          elif (( index + 1 < count )); then
            index=$((index + 1))
            carried=${shell_args[index]}
          fi
          [[ -n $carried ]] || return 1
          printf '%s\n' "${carried//$qmark/$apostrophe}"
          return 0
          ;;
      esac
      expect_value=0
      [[ "$word" == -o || "$word" == -O ]] && expect_value=1
      continue
    fi
    (( expect_value )) || return 1
    expect_value=0
  done
  return 1
}

__lmline_risk_shell_carries_remove() {
  local depth=$1 subst_body=${2:-0} carried nested_payload
  shift 2
  while IFS= read -r carried || [[ -n $carried ]]; do
    [[ -n $carried ]] || continue
    # A substitution supplies the command string only in command
    # position; elsewhere its output is data to another command.
    if __lmline_risk_substitution_in_command_position "$carried"; then
      # Every substitution in a -c string helps build the command string,
      # even one that is an argument where the string itself is parsed.
      __lmline_risk_substitution_payload_remove "$carried" $((depth + 1)) 1 && return 0
    fi
    if (( subst_body )); then
      while IFS= read -r nested_payload || [[ -n $nested_payload ]]; do
        [[ -n $nested_payload ]] || continue
        __lmline_risk_recursive_remove "$nested_payload" $((depth + 1)) && return 0
      done < <(__lmline_risk_here_string_payload "$carried" 0)
    fi
    __lmline_risk_recursive_remove "$carried" $((depth + 1)) && return 0
  done < <(__lmline_risk_shell_c_command_strings "$@")
  return 1
}

# Command strings the shell command words in a command run through -c. The
# whole command is read once so a command substitution feeding -c stays one
# argument; segments then cover shells hidden behind other commands.
__lmline_risk_shell_c_command_strings_in() {
  local cmd=$1 segment word index cmd_index raw_index
  local -a words raw_words source_words
  if [[ $cmd == *'$('* || $cmd == *'`'* ]]; then
    raw_words=()
    source_words=()
    mapfile -t raw_words < <(__lmline_risk_split_words "$cmd")
    mapfile -t source_words < <(__lmline_risk_split_words "$cmd" 1)
    raw_index=$(__lmline_risk_segment_command_index "${raw_words[@]}") || raw_index=-1
    if (( raw_index >= 0 )) && __lmline_risk_word_runs_shell "${raw_words[raw_index]}"; then
      __lmline_risk_shell_c_command_strings "${source_words[@]:raw_index+1}"
      return 0
    fi
  fi
  while IFS= read -r segment || [[ -n $segment ]]; do
    [[ -n "${segment//[[:space:]]/}" ]] || continue
    words=()
    source_words=()
    mapfile -t words < <(__lmline_risk_split_words "$segment")
    mapfile -t source_words < <(__lmline_risk_split_words "$segment" 1)
    ((${#words[@]})) || continue
    cmd_index=$(__lmline_risk_segment_command_index_with "$segment" "${words[@]}") || continue
    word=${words[cmd_index]}
    __lmline_risk_word_runs_shell "$word" || continue
    __lmline_risk_shell_c_command_strings "${source_words[@]:cmd_index+1}"
  done <<<"$(__lmline_split_pipeline "$cmd" 1 "()" bash structural-substitution)"
  return 0
}

# The structural splitter marks a substitution opener with a standalone `$`
# word. Assignments and shell structure before it leave it in command
# position; any other earlier word makes its output plain data.
__lmline_risk_substitution_marker_line() {
  local segment=$1 word index earlier skip_target
  local -a words=()
  mapfile -t words < <(__lmline_risk_split_words "$segment")
  for ((index = 0; index < ${#words[@]}; index++)); do
    [[ ${words[index]} == '$' ]] || continue
    skip_target=0
    for ((earlier = 0; earlier < index; earlier++)); do
      word=${words[earlier]}
      if (( skip_target )); then
        skip_target=0
        continue
      fi
      [[ $word == *=* ]] && continue
      if __lmline_risk_descriptor_duplication_word "$word"; then
        continue
      fi
      if __lmline_risk_redirect_word "$word"; then
        (( __LMLINE_RISK_REDIRECT_TARGET )) && skip_target=1
        continue
      fi
      __lmline_word_is_command_prefix "$word" && continue
      break
    done
    (( skip_target )) && continue
    (( earlier == index )) && return 0
  done
  return 1
}

__lmline_risk_substitution_in_command_position() {
  local text=$1 segment
  while IFS= read -r segment || [[ -n $segment ]]; do
    __lmline_risk_substitution_marker_line "$segment" && return 0
  done <<<"$(__lmline_split_pipeline "$text" 1 "()" bash structural-substitution-marker)"
  return 1
}

# The text a command substitution can hand back to a command string: literal
# here-string data copied by its body, and the body itself. The body is read,
# never executed.
__lmline_risk_substitution_occurrence_command_position() {
  local text=$1 segment last=
  while IFS= read -r segment || [[ -n $segment ]]; do
    last=$segment
  done < <(__lmline_split_pipeline "${text}\$" 1 "()" bash structural-substitution-marker)
  __lmline_risk_substitution_marker_line "$last"
}

__lmline_risk_substitution_command_payloads() {
  local text=$1 all=${2:-0} rest prefix after body dollar_pos backtick_pos pos skip payload
  rest=$text
  while :; do
    dollar_pos=-1
    backtick_pos=-1
    if [[ $rest == *'$('* ]]; then
      prefix=${rest%%'$('*}
      dollar_pos=${#prefix}
    fi
    if [[ $rest == *'`'* ]]; then
      prefix=${rest%%'`'*}
      backtick_pos=${#prefix}
    fi
    (( dollar_pos >= 0 )) || (( backtick_pos >= 0 )) || break
    if (( backtick_pos >= 0 && (dollar_pos < 0 || backtick_pos < dollar_pos) )); then
      pos=$backtick_pos
      after=${rest:pos+1}
      [[ $after == *'`'* ]] || break
      body=${after%%'`'*}
      skip=$((pos + ${#body} + 2))
    else
      pos=$dollar_pos
      after=${rest:pos+2}
      [[ $after == *')'* ]] || break
      body=${after%%')'*}
      skip=$((pos + ${#body} + 3))
    fi
    prefix=${rest:0:pos}
    if [[ -n $body ]] && { (( all )) || __lmline_risk_substitution_occurrence_command_position "$prefix"; }; then
      while IFS= read -r payload || [[ -n $payload ]]; do
        [[ -n $payload ]] || continue
        printf '%s\n' "$payload"
      done < <(__lmline_risk_here_string_payload "$body" 0 1)
      printf '%s\n' "$body"
    fi
    rest=${rest:skip}
  done
}

# A command substitution can provide the command string a shell runs. Judge
# the data it can hand back as that command string.
__lmline_risk_substitution_payload_remove() {
  local text=$1 depth=$2 all=${3:-0} payload match
  (( depth < 4 )) || return 1
  while IFS= read -r payload || [[ -n $payload ]]; do
    [[ -n $payload ]] || continue
    __lmline_risk_recursive_remove "$payload" $((depth + 1)) && return 0
    # A payload that builds a command string can carry risks other than a
    # recursive remove, so judge it with the same rules as the outer command.
    match=$(__lmline_risk_match "$payload" $((depth + 1))) || return 1
    [[ ${match%%$'\t'*} == high ]] && return 0
  done < <(__lmline_risk_substitution_command_payloads "$text" "$all")
  return 1
}

# A recursive remove is the same destructive command however its flags are
# written, so the removal family is recognised by the word in the position a
# command occupies and by the flags written with it, not by the order of the
# text. That position is the command the shell runs: the command word of the
# simple command, or the command a program that runs another program carries.
# A word that merely carries the name of a remove is not the family, so the
# family reads the same way in every spelling. A shell command word runs the
# command string it is given after -c, so a remove written there is judged as
# the remove it is.
__lmline_risk_recursive_remove() {
  local cmd=$1 depth=${2:-0} segment word base
  local count cmd_index raw_index index subst_body backtick_body argument
  local -a words raw_words
  (( depth < 4 )) || return 1
  # The structural splitter cuts at substitution parentheses, and the rm
  # itself can land in a later segment than the shell. Read the whole command
  # once so a command substitution feeding -c stays one argument.
  if [[ $cmd == *'$('* || $cmd == *'`'* ]]; then
    raw_words=()
    mapfile -t raw_words < <(__lmline_risk_split_words "$cmd")
    raw_index=$(__lmline_risk_segment_command_index "${raw_words[@]}") || raw_index=-1
    if (( raw_index >= 0 )) && __lmline_risk_word_runs_shell "${raw_words[raw_index]}"; then
      subst_body=0
      if [[ $cmd == *'`'* ]]; then
        backtick_body=${cmd#*'`'}
        backtick_body=${backtick_body%%'`'*}
        for ((index = raw_index + 1; index < ${#raw_words[@]}; index++)); do
          [[ ${raw_words[index]} == -*c* ]] || continue
          argument=${raw_words[index]#*c}
          if [[ -z $argument ]] && (( index + 1 < ${#raw_words[@]} )); then
            argument=${raw_words[index+1]}
          fi
          [[ $argument == "$backtick_body" ]] && subst_body=1
          break
        done
      fi
      __lmline_risk_shell_carries_remove $((depth + 1)) "$subst_body" "${raw_words[@]:raw_index+1}" && return 0
    fi
  fi
  while IFS= read -r segment || [[ -n $segment ]]; do
    [[ -n "${segment//[[:space:]]/}" ]] || continue
    [[ "$segment" == *rm* ]] || continue
    words=()
    while IFS= read -r word || [[ -n $word ]]; do
      words+=("$word")
    done < <(__lmline_risk_split_words "$segment")
    count=${#words[@]}
    # The command the segment runs. A program that runs another program hands
    # the command it runs to the next program, so the chain is followed to
    # the command that runs.
    # The decoded words lose quoting, so carry the segment itself for the
    # coproc name check.
    cmd_index=$(__lmline_risk_segment_command_index_with "$segment" "${words[@]}") || continue
    word=${words[cmd_index]}
    if __lmline_risk_word_runs_shell "$word"; then
      # A shell command word runs the command string it is given after -c.
      __lmline_risk_shell_carries_remove $((depth + 1)) 0 "${words[@]:cmd_index+1}" && return 0
      continue
    fi
    # The command the segment runs. Its own flags follow it, so the words
    # after it are read as the flags it writes.
    __lmline_risk_remove_word_is_recursive "$word" "${words[@]:cmd_index+1}" && return 0
  done <<<"$(__lmline_split_pipeline "$cmd" 1 "()" bash structural-substitution)"
  return 1
}

# One word judged as a command position: strip shell substitution syntax
# around it, then lose its directory prefix. Other words are returned as
# written, so a path that is only an argument keeps its own text.
__lmline_risk_basename_word() {
  local word=$1 inner clean_word base opener="" closer=""
  local -a clean_parts
  mapfile -t clean_parts < <(__lmline_risk_split_words "$word")
  ((${#clean_parts[@]})) || { printf '%s' "$word"; return 0; }
  clean_word=${clean_parts[0]}
  inner=$clean_word
  while :; do
    case $inner in
      '$('*) opener+='$('; inner=${inner#\$'('} ;;
      '<('*) opener+='<('; inner=${inner#'<('} ;;
      '`'*) opener+='`'; inner=${inner#\`} ;;
      *) break ;;
    esac
  done
  while :; do
    case $inner in
      *')') closer=")$closer"; inner=${inner%\)} ;;
      *'`') closer="\`$closer"; inner=${inner%\`} ;;
      *) break ;;
    esac
  done
  case $inner in '' | *[!A-Za-z0-9_./-]*) printf '%s' "$word"; return 0 ;; esac
  base=${inner##*/}
  [[ $base != "$inner" ]] || { printf '%s' "$word"; return 0; }
  printf '%s' "$opener$base$closer"
}

# Whether a word contains the delimiter outside quotes and escapes. A
# delimiter written inside quotes is data, not the end of a substitution.
__lmline_risk_word_has_unquoted_char() {
  local text=$1 target=$2 i ch quote="" escaped=0
  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    if [[ -n $quote ]]; then
      # A backslash is literal inside single quotes but escapes the next
      # character in double quotes and backticks, even runs of backslashes.
      if [[ $quote == "'" ]]; then
        [[ $ch == "'" ]] && quote=
        continue
      fi
      if (( escaped )); then
        escaped=0
        continue
      fi
      if [[ $ch == "\\" ]]; then
        escaped=1
        continue
      fi
      [[ $ch == "$quote" ]] && quote=
      continue
    fi
    if (( escaped )); then
      escaped=0
      continue
    fi
    if [[ $ch == "\\" ]]; then
      escaped=1
      continue
    fi
    [[ $ch == "$target" ]] && return 0
    case $ch in
      "'"|'"'|"\`") quote=$ch ;;
    esac
  done
  return 1
}

# One signal spelling as the shipped rules name it: case-folded names, an
# optional SIG prefix removed, and numeric signals without leading zeros.
__lmline_risk_canonical_signal() {
  local signal=${1,,}
  signal=${signal#sig}
  if [[ $signal =~ ^[0-9]+$ ]]; then
    while [[ ${#signal} -gt 1 && $signal == 0* ]]; do
      signal=${signal#0}
    done
    printf '%s\n' "$signal"
  else
    printf '%s\n' "$signal"
  fi
}

# Canonicalize the signal spec of a kill command in the view the policy rules
# match. Other commands keep their text; a signal spec that is not recognized
# is left as written so the ordinary rules still judge it.
__lmline_risk_canonicalize_kill_signals_in_view() {
  local view=$1 i j word signal canonical
  local -a words normalized
  read -r -a words <<<"$view" || true
  ((${#words[@]})) || { printf '%s' "$view"; return 0; }
  normalized=("${words[@]}")
  for ((i = 0; i < ${#words[@]}; i++)); do
    [[ ${words[i]##*/} == kill ]] || continue
    for ((j = i + 1; j < ${#words[@]}; j++)); do
      word=${words[j]}
      case $word in
        -[sSnN])
          ((j + 1 < ${#words[@]})) || break
          canonical=$(__lmline_risk_canonical_signal "${words[j+1]}") || break
          normalized[j + 1]=$canonical
          ((j++))
          ;;
        -[SN]*)
          # An uppercase letter can start a signal name, not an option.
          # Keep only spellings that name SIGKILL as a signal.
          signal=${word#-}
          canonical=$(__lmline_risk_canonical_signal "$signal") || break
          [[ $canonical == kill ]] || break
          normalized[j]="-$canonical"
          ;;
        -s*)
          signal=${word:2}
          [[ -n $signal ]] || break
          canonical=$(__lmline_risk_canonical_signal "$signal") || break
          normalized[j]="-s$canonical"
          ;;
        -n*)
          signal=${word:2}
          [[ $signal =~ ^[0-9]+$ ]] || break
          canonical=$(__lmline_risk_canonical_signal "$signal") || break
          normalized[j]="-n$canonical"
          ;;
        -*)
          signal=${word#-}
          canonical=$(__lmline_risk_canonical_signal "$signal") || break
          normalized[j]="-$canonical"
          ;;
      esac
    done
  done
  printf '%s' "${normalized[*]}"
}

__lmline_risk_canonicalize_kill_signal() {
  local view=$1 index base word start=-1 tail
  local -a words=()
  read -r -a words <<<"$view" || true
  ((${#words[@]})) || { printf '%s' "$view"; return 0; }
  index=$(__lmline_risk_segment_command_index "${words[@]}") || {
    printf '%s' "$view"
    return 0
  }
  base=${words[index]##*/}
  if [[ ${base,,} == kill ]]; then
    __lmline_risk_canonicalize_kill_signals_in_view "$view"
    return 0
  fi
  # A shell runs the command string after -c; its kill spells the same signal.
  if __lmline_word_is_shell "$base"; then
    for ((index = index + 1; index < ${#words[@]}; index++)); do
      word=${words[index]}
      [[ $word == -* && ${word#-} == *c* ]] || continue
      start=$((index + 1))
      break
    done
    if ((start >= 0 && start < ${#words[@]})); then
      tail=$(__lmline_risk_canonicalize_kill_signals_in_view "${words[*]:start}")
      printf '%s %s' "${words[*]:0:start}" "$tail"
      return 0
    fi
  fi
  printf '%s' "$view"
}

# Apply a view transform to each simple command, keeping the separators in
# place. Walking segments preserves command boundaries that the final flat
# view no longer shows.
__lmline_risk_map_segments() {
  local view=$1 transform=$2 segment rest prefix out="" cursor=0
  local lead trail body
  while IFS= read -r segment; do
    rest=${view:cursor}
    if [[ -z $segment || $rest != *"$segment"* ]]; then
      continue
    fi
    prefix=${rest%%"$segment"*}
    out+=$prefix
    if [[ -z ${segment//[[:space:]]/} ]]; then
      out+=$segment
    else
      lead=${segment%%[![:space:]]*}
      trail=${segment##*[![:space:]]}
      body=${segment:${#lead}:${#segment}-${#lead}-${#trail}}
      out+=$lead
      out+=$("$transform" "$body")
      out+=$trail
    fi
    cursor=$((cursor + ${#prefix} + ${#segment}))
  done < <(__lmline_split_pipeline "$view" 1)
  printf '%s' "$out${view:cursor}"
}

# Decode quoting, ${IFS} and escapes in one simple command before the policy
# view is matched.
__lmline_risk_decode_segment_for_risk() {
  local segment=$1
  # A shell -c payload keeps list separators inside its quoted word. Show
  # them as pipe boundaries before decoding so end-of-options stays local to
  # the command that wrote it.
  segment=${segment//&&/ | }
  segment=${segment//&/ | }
  segment=${segment//||/ | }
  segment=${segment//;/ | }
  __lmline_canonicalize_for_risk <<<"$segment" | tr -s '[:space:]' ' '
}

# The command positions of one pipeline segment, as word-index/replacement
# pairs. The indices count the same whitespace-delimited words the reader
# below sees, so only those words are rewritten when the view is assembled.
# After --, a flag-shaped word is a literal operand. Give the policy view a
# neutral token for those words so flag patterns cannot mistake them for
# options, while the operands themselves keep their text.
__lmline_risk_neutralize_segment_flags_after_double_dash() {
  local view=$1 word out="" after=0
  local -a words=()
  read -r -a words <<<"$view" || true
  for word in "${words[@]}"; do
    if (( after )) && [[ $word == -* ]]; then
      word=--literal-operand--
    fi
    [[ $word == -- ]] && after=1
    out+=" $word"
  done
  printf '%s' "${out# }"
}

# A word after a find name test is operand text, and a longer -delete...
# spelling is not find's delete action. Give the pattern view a neutral token
# for those words while leaving the real action untouched. This runs before
# decoding so an empty or quoted-away operand is still a visible token.
__lmline_risk_neutralize_find_delete_operand_segment() {
  local view=$1 word plain out="" operand=0 cmd_index index
  local -a words=()
  read -r -a words <<<"$view" || true
  ((${#words[@]})) || { printf '%s' "$view"; return 0; }
  cmd_index=$(__lmline_risk_segment_command_index "${words[@]}") || { printf '%s' "$view"; return 0; }
  [[ ${words[cmd_index]##*/} == find ]] || { printf '%s' "$view"; return 0; }
  for ((index = 0; index < ${#words[@]}; index++)); do
    word=${words[index]}
    plain=$(__lmline_unquote_simple_word "$word")
    # The pattern view decodes backslashes later; decode them here too so an
    # escaped operand cannot masquerade as find's delete action.
    plain=${plain//\\/}
    if (( index > cmd_index )); then
      if (( operand )); then
        [[ $plain == -delete* ]] && word=--literal-operand--
        operand=0
      elif [[ $plain == -delete* && $plain != -delete ]]; then
        word=--literal-operand--
      else
        case $plain in
          -name|-iname|-path|-ipath|-wholename|-iwholename|-regex|-iregex|-lname|-ilname)
            operand=1
            ;;
        esac
      fi
    fi
    out+=" $word"
  done
  printf '%s' "${out# }"
}

__lmline_risk_neutralize_find_delete_operand() {
  __lmline_risk_map_segments "$1" __lmline_risk_neutralize_find_delete_operand_segment
}

# -- ends options for one simple command, not for the rest of the line.
__lmline_risk_neutralize_flags_after_double_dash() {
  __lmline_risk_map_segments "$1" __lmline_risk_neutralize_segment_flags_after_double_dash
}

__lmline_risk_basename_command_replacements() {
  local segment=$1 word index prefix_base cmd_index replacement j k start close_index target
  local inner base scan closer
  local -a words sub_words clean_parts
  local IFS=$' \t\n'
  words=()
  read -r -a words <<<"$segment" || true
  ((${#words[@]} > 0)) || return 0
  index=0
  while ((index < ${#words[@]})); do
    word=${words[index]}
    [[ $word == *=* || $word == -* ]] && { index=$((index + 1)); continue; }
    break
  done
  ((index < ${#words[@]})) || return 0
  # A runner hands its command word to the program it runs; a shell syntax
  # prefix also stands before that command. The shared carried-command
  # parser knows both from one vocabulary. A substitution is read below:
  # its runner stops at the closing delimiter, not at the end of the line.
  case ${words[index]} in
    '$('*|'<('*|'`'*) ;;
    *)
      mapfile -t clean_parts < <(__lmline_risk_split_words "${words[index]}")
      ((${#clean_parts[@]})) || return 0
      prefix_base=${clean_parts[0]##*/}
      if __lmline_risk_is_runner "$prefix_base" ||
        __lmline_word_is_command_prefix "$prefix_base"; then
        cmd_index=$(__lmline_risk_carried_command_index "${words[@]:index}") || return 0
        index=$((index + cmd_index))
      fi
      ;;
  esac
  word=${words[index]}
  replacement=$(__lmline_risk_basename_word "$word")
  [[ $replacement == "$word" ]] || printf '%s\t%s\n' "$index" "$replacement"
  # A command substitution opens its own command position wherever it
  # appears in the segment, including as the command word of the segment.
  # Its words are read as data, so quoting around a runner does not hide it.
  for ((j = 0; j < ${#words[@]}; j++)); do
    word=${words[j]}
    case $word in
      '$('*|'<('*|'`'*) ;;
      *) continue ;;
    esac
    mapfile -t clean_parts < <(__lmline_risk_split_words "$word")
    inner=${clean_parts[0]:-}
    case $inner in
      '$('*) inner=${inner#\$'('} ;;
      '<('*) inner=${inner#'<('} ;;
    esac
    closer=')'
    [[ $word == '`'* ]] && closer='`'
    # A path after the closing delimiter is an operand of the outer
    # command. An opener without a delimiter runs no command at all.
    close_index=-1
    for ((k = j; k < ${#words[@]}; k++)); do
      scan=${words[k]}
      if (( k == j )); then
        scan=${scan#\$'('}
        scan=${scan#'<('}
        scan=${scan#'`'}
      fi
      if __lmline_risk_word_has_unquoted_char "$scan" "$closer"; then
        close_index=$k
        break
      fi
    done
    (( close_index >= 0 )) || continue
    # A path glued to the opener is the command the substitution runs,
    # even when the delimiter is written in the same word.
    replacement=$(__lmline_risk_basename_word "$word")
    if [[ $replacement != "$word" ]]; then
      printf '%s\t%s\n' "$j" "$replacement"
      continue
    fi
    (( close_index > j )) || continue
    start=$j
    if [[ -z $inner ]]; then
      # The opener stands alone, so the command is the next word.
      start=$((j + 1))
      (( start <= close_index )) || continue
      word=${words[start]}
      replacement=$(__lmline_risk_basename_word "$word")
      if [[ $replacement != "$word" ]]; then
        printf '%s\t%s\n' "$start" "$replacement"
        continue
      fi
      mapfile -t clean_parts < <(__lmline_risk_split_words "$word")
      ((${#clean_parts[@]})) || continue
      inner=${clean_parts[0]}
    fi
    inner=${inner%)}
    inner=${inner#'`'}
    base=${inner##*/}
    if __lmline_risk_is_runner "$base" ||
      __lmline_word_is_command_prefix "$base"; then
      (( close_index > start )) || continue
      sub_words=("$base" "${words[@]:start+1:close_index-start}")
      cmd_index=$(__lmline_risk_carried_command_index "${sub_words[@]}") || continue
      target=$((start + cmd_index))
      (( target <= close_index )) || continue
      word=${words[target]}
      replacement=$(__lmline_risk_basename_word "$word")
      [[ $replacement == "$word" ]] || printf '%s\t%s\n' "$target" "$replacement"
    fi
  done
}

# Judge a command written by absolute or relative path by its program name,
# as the bare spelling is judged. Only the command word of each pipeline
# segment loses its directory prefix; path operands keep their text, so a
# harmless path containing a dangerous name is not turned into that command.
__lmline_risk_basename_command_words() {
  local cmd=$1 segment out="" cursor=0 rest prefix normalized index replacement token i ch start
  local -A replacements=()
  local IFS=$' \t\n'
  [[ $cmd == */* ]] || { printf '%s' "$cmd"; return 0; }
  while IFS= read -r segment || [[ -n $segment ]]; do
    rest=${cmd:cursor}
    # The splitter only turns separators into newlines, so every segment is
    # a contiguous piece of the original command. Text that cannot be
    # matched stays in the untouched tail appended at the end.
    if [[ -z $segment || $rest != *"$segment"* ]]; then
      continue
    fi
    prefix=${rest%%"$segment"*}
    out+=${cmd:cursor:${#prefix}}
    cursor=$((cursor + ${#prefix} + ${#segment}))
    replacements=()
    while IFS=$'\t' read -r index replacement; do
      replacements[$index]=$replacement
    done < <(__lmline_risk_basename_command_replacements "$segment")
    normalized=$segment
    if ((${#replacements[@]})); then
      normalized="" token=0 i=0
      while ((i < ${#segment})); do
        ch=${segment:i:1}
        if [[ $ch == ' ' || $ch == $'\t' ]]; then
          normalized+=$ch
          i=$((i + 1))
          continue
        fi
        start=$i
        while ((i < ${#segment})) && [[ ${segment:i:1} != ' ' && ${segment:i:1} != $'\t' ]]; do
          i=$((i + 1))
        done
        if [[ -n ${replacements[$token]+set} ]]; then
          normalized+=${replacements[$token]}
        else
          normalized+=${segment:start:i-start}
        fi
        token=$((token + 1))
      done
    fi
    out+=$normalized
  done < <(__lmline_split_pipeline "$cmd" 1)
  printf '%s' "$out${cmd:cursor}"
}

# A here-string operator with no descriptor feeds stdin; an explicit N<<<
# operator feeds descriptor N. Return the descriptor for an active operator.
__lmline_risk_here_string_descriptor() {
  local word=$1 prefix
  prefix=${word%%[!0-9]*}
  [[ ${word:${#prefix}:3} == '<<<' ]] || return 1
  [[ -n $prefix ]] || prefix=0
  printf '%s\n' "$((10#$prefix))"
}

# A standard-stream path names the descriptor a shell reads its script from,
# not a stored script file. Quotes are removed before the path is read: the
# quote-preserving view keeps them in a word such as "/dev/stdin". The
# descriptor decides which input can actually carry that script.
__lmline_risk_stream_script_alias_descriptor() {
  local -a parts=()
  mapfile -t parts < <(__lmline_risk_split_words "$1")
  ((${#parts[@]} == 1)) || return 1
  local word=${parts[0]} fd
  if [[ $word == /dev/stdin ]]; then
    fd=0
  elif [[ $word =~ ^/dev/fd/([0-9]+)$ ]]; then
    fd=$((10#${BASH_REMATCH[1]}))
  elif [[ $word =~ ^/proc/(self|[0-9]+)/fd/([0-9]+)$ ]]; then
    fd=$((10#${BASH_REMATCH[2]}))
  else
    return 1
  fi
  printf '%s\n' "$fd"
}

# The one active-redirect check for the quote-preserving word view: an operator
# at the start of a word (after an optional numeric descriptor), which includes
# a here-string. Set __LMLINE_RISK_REDIRECT_TARGET when the operator ends its
# word, so the next word is its separated target rather than a glued one.
__lmline_risk_redirect_word() {
  local word=$1 prefix
  __LMLINE_RISK_REDIRECT_TARGET=0
  prefix=${word%%[!0-9]*}
  case ${word:${#prefix}:1} in
    '<'|'>'|'|')
      case $word in
        *'<'|*'>'|*'|'|*'&') __LMLINE_RISK_REDIRECT_TARGET=1 ;;
      esac
      return 0
      ;;
    '&')
      # &> redirects both streams; a bare & is a command boundary.
      [[ ${word:1:1} == '>' ]] || return 1
      [[ $word == *'>' ]] && __LMLINE_RISK_REDIRECT_TARGET=1
      return 0
      ;;
  esac
  return 1
}

# A descriptor duplication such as 3>&0 or <&0 copies an open descriptor
# instead of naming a file. Report its target and source descriptors; an
# omitted target defaults to fd 0 for input and fd 1 for output.
__lmline_risk_descriptor_duplication_word() {
  local word=$1 pattern='^([0-9]*)([<>])&([0-9]+)$' operator target source
  [[ $word =~ $pattern ]] || return 1
  operator=${BASH_REMATCH[2]}
  target=${BASH_REMATCH[1]}
  source=${BASH_REMATCH[3]}
  [[ -n $target ]] || target=$([[ $operator == '<' ]] && printf '0' || printf '1')
  __LMLINE_RISK_DUP_TARGET=$((10#$target))
  __LMLINE_RISK_DUP_SOURCE=$((10#$source))
}

# Verbatim stdin producers whose output carries the here-string into a
# command substitution. An unknown or no-output producer is not assumed to
# copy its input.
__lmline_risk_word_copies_stdin() {
  case ${1##*/} in
    cat|tee) return 0 ;;
  esac
  return 1
}

# tee copies stdin to stdout even when file operands are present; cat instead
# reads those files and stops using stdin.
__lmline_risk_word_copies_stdin_with_operands() {
  [[ ${1##*/} == tee ]]
}

# A stdout redirection on the copying producer keeps its bytes out of the
# command substitution, so the here-string cannot become a command string.
# Decode one option word the way the shell would pass it to a program.
# Quotes are removed; backslashes are escapes only outside quotes (and for the
# few escapable characters inside double quotes), never inside single quotes.
__lmline_risk_decode_option_word() {
  local word=$1 out="" quote="" i=0 ch next
  __LMLINE_RISK_OPTION_WORD=
  while (( i < ${#word} )); do
    ch=${word:i:1}
    if [[ $ch == '$' && ${word:i+1:1} == "'" ]]; then
      i=$((i + 2))
      while (( i < ${#word} )); do
        ch=${word:i:1}
        if [[ $ch == "'" ]]; then i=$((i + 1)); break; fi
        if [[ $ch == '\' ]]; then
          i=$((i + 1))
          ch=${word:i:1}
          case $ch in
            n) out+=$'\n' ;;
            t) out+=$'\t' ;;
            r) out+=$'\r' ;;
            *) out+=$ch ;;
          esac
        else
          out+=$ch
        fi
        i=$((i + 1))
      done
      continue
    fi
    if [[ -n $quote ]]; then
      if [[ $ch == "$quote" ]]; then quote=; i=$((i + 1)); continue; fi
      if [[ $quote == '"' && $ch == '\' ]]; then
        next=${word:i+1:1}
        case $next in
          '$'|'`'|'"'|'\'|'') out+=$next; i=$((i + 2)) ;;
          *) out+='\'; i=$((i + 1)) ;;
        esac
        continue
      fi
      out+=$ch
      i=$((i + 1))
      continue
    fi
    case $ch in
      "'"|'"') quote=$ch; i=$((i + 1)) ;;
      '\') i=$((i + 1)); out+=${word:i:1}; i=$((i + 1)) ;;
      *) out+=$ch; i=$((i + 1)) ;;
    esac
  done
  __LMLINE_RISK_OPTION_WORD=$out
}

# Shells read stdin as the script when -s occurs in the option prefix. Long
# options and short bundles need their own values skipped before that prefix
# ends; once -s is seen later words are positional parameters, not a script.
__lmline_risk_shell_stdin_script() {
  local start=$1 index word option base seen_s=0 command_string=0
  shift
  local -a words=("$@")
  for ((index = start + 1; index < ${#words[@]}; index++)); do
    word=${words[index]}
    if __lmline_risk_here_string_descriptor "$word" >/dev/null; then
      [[ $word == *'<<<' ]] && index=$((index + 1))
      continue
    fi
    if __lmline_risk_redirect_word "$word"; then
      (( __LMLINE_RISK_REDIRECT_TARGET )) && index=$((index + 1))
      continue
    fi
    # The quote-preserving view keeps shell quotes and escapes; option names
    # must be read as the shell would read them.
    __lmline_risk_decode_option_word "$word"
    option=$__LMLINE_RISK_OPTION_WORD
    [[ $option == -- ]] && break
    if [[ $option != -* ]]; then
      (( seen_s )) && continue
      break
    fi
    if [[ $option == --* ]]; then
      [[ $option == *=* ]] && continue
      base=${option%%=*}
      case $base in
        --rcfile|--init-file|--o|--O|--op|--optimization|--rpm|--wordchars|--histchars)
          index=$((index + 1))
          ;;
      esac
      continue
    fi
    if [[ $option == *c* ]]; then command_string=1; break; fi
    [[ $option == *s* ]] && seen_s=1
    [[ $option == *[oO]* ]] && index=$((index + 1))
  done
  (( seen_s && ! command_string ))
}

__lmline_risk_word_sinks_stdout() {
  local word=$1 target
  [[ $word == '&>'* ]] && return 0
  [[ $word =~ ^([0-9]*)'>' ]] || return 1
  target=${BASH_REMATCH[1]}
  [[ -n $target ]] || target=1
  (( 10#$target == 1 ))
}

# Follow descriptor duplications after a script-carrying operator in source
# order. Each duplication overwrites its target with its source: a copied
# carrier joins the set, and a target overwritten from a non-carrier leaves it.
# The resulting descriptor set is published in __LMLINE_RISK_CARRIED_FDS for
# the caller to read immediately after the call. Nothing is executed here.
declare -ga __LMLINE_RISK_CARRIED_FDS=()
__lmline_risk_carry_fds() {
  local initial_fd=$1 start=$2 index target source fd source_carries
  shift 2
  local -a words=("$@") carried=() kept=()
  __LMLINE_RISK_CARRIED_FDS=()
  [[ -n $initial_fd ]] || return 0
  carried=($((10#$initial_fd)))
  for ((index = start; index < ${#words[@]}; index++)); do
    __lmline_risk_descriptor_duplication_word "${words[index]}" || continue
    target=$__LMLINE_RISK_DUP_TARGET
    source=$__LMLINE_RISK_DUP_SOURCE
    source_carries=0
    for fd in "${carried[@]}"; do
      [[ $source == "$fd" ]] && { source_carries=1; break; }
    done
    kept=()
    for fd in "${carried[@]}"; do
      [[ $fd == "$target" ]] || kept+=("$fd")
    done
    carried=("${kept[@]}")
    (( source_carries )) || continue
    for fd in "${carried[@]}"; do
      [[ $fd == "$target" ]] && { source_carries=0; break; }
    done
    (( source_carries )) && carried+=("$target")
  done
  __LMLINE_RISK_CARRIED_FDS=("${carried[@]}")
}

# The script a shell reads from an active here-string operator. The unquoted
# view proves an operator is active: a quoted or escaped operator has no
# standalone token there. That view can drop a quoted command word, so the
# quote-preserving view supplies the command and all simple-command words.
# Both views are read without executing anything. One payload per line.
__lmline_risk_here_string_payload() {
  local cmd=$1 require_shell=${2:-1} require_copy=${3:-0} segment marker word payload
  local index cmd_index op_index script_word=0 stdin_script=0 copies_with_operands=0 stdout_sunk=0 active fd alias_matches carried_fd reaches alias_claimed
  local -a plain=() quoted=() words=()
  local IFS=$' \t\n'
  printf -v marker '\002'
  while IFS= read -r segment || [[ -n $segment ]]; do
    stdin_script=0
    mapfile -t plain < <(__lmline_risk_split_words "$(__lmline_split_pipeline "$segment" 0)")
    ((${#plain[@]})) || continue
    active=0
    for ((index = 0; index < ${#plain[@]}; index++)); do
      fd=$(__lmline_risk_here_string_descriptor "${plain[index]}") || continue
      active=1
      break
    done
    (( active )) || continue
    read -r -a quoted <<<"$(__lmline_split_pipeline "$segment" 2)"
    ((${#quoted[@]})) || continue
    cmd_index=$(__lmline_risk_segment_command_index "${quoted[@]}") || continue
    if (( require_shell )); then
      if ! __lmline_risk_word_runs_shell "${quoted[cmd_index]}" &&
         ! __lmline_risk_word_sources_script "${quoted[cmd_index]}"; then
        continue
      fi
    fi
    if (( require_copy )) && ! __lmline_risk_word_copies_stdin "${quoted[cmd_index]}"; then
      continue
    fi
    copies_with_operands=0
    if (( require_copy )) && __lmline_risk_word_copies_stdin_with_operands "${quoted[cmd_index]}"; then
      copies_with_operands=1
    fi
    # With -s the shell reads its script from stdin whatever follows it, but
    # only when -s is in the option prefix and no -c selected a command string.
    stdin_script=0
    __lmline_risk_shell_stdin_script "$cmd_index" "${quoted[@]}" && stdin_script=1
    for ((op_index = cmd_index + 1; op_index < ${#quoted[@]}; op_index++)); do
      # A payload can be glued to the operator; ANSI-C quoting was already
      # decoded by the caller, so both spellings start with the operator here.
      fd=$(__lmline_risk_here_string_descriptor "${quoted[op_index]}") || continue
      stdout_sunk=0
      # Only duplication after the operator copies the here-string's fd;
      # an earlier one copied the stdin that preceded the operator.
      __lmline_risk_carry_fds "$fd" $((op_index + 1)) "${quoted[@]}"
      reaches=0
      alias_claimed=0
      for carried_fd in "${__LMLINE_RISK_CARRIED_FDS[@]}"; do
        [[ $carried_fd == 0 ]] && { reaches=1; break; }
      done
      # A command string or script file already gives the shell its input, so
      # the here-string is data to that program, not a script it reads.
      script_word=0
      for ((index = cmd_index + 1; index < ${#quoted[@]}; index++)); do
        word=${quoted[index]}
        (( stdin_script )) && continue
        # A standalone earlier here-string consumes its payload word, so that
        # word is not a script file given to the shell.
        if __lmline_risk_here_string_descriptor "$word" >/dev/null; then
          # A standalone operator consumes the next word; a glued payload is
          # already in the operator word and leaves the next word visible.
          [[ $word == *'<<<' ]] && index=$((index + 1))
          continue
        fi
        if __lmline_risk_redirect_word "$word"; then
          (( require_copy )) && __lmline_risk_word_sinks_stdout "$word" && stdout_sunk=1
          (( __LMLINE_RISK_REDIRECT_TARGET )) && index=$((index + 1))
          continue
        fi
        (( copies_with_operands )) && continue
        # An alias reads the payload when its descriptor is the here-string's
        # own or one a later duplication copied it to; otherwise it is a file.
        fd=$(__lmline_risk_stream_script_alias_descriptor "$word") || fd=
        if [[ -n $fd ]]; then
          alias_matches=0
          for carried_fd in "${__LMLINE_RISK_CARRIED_FDS[@]}"; do
            if [[ $fd == "$carried_fd" ]]; then alias_matches=1; break; fi
          done
          if (( alias_matches )); then
            reaches=1
            alias_claimed=1
            continue
          fi
        fi
        if [[ $word == -[oO] ]]; then
          index=$((index + 1))
          continue
        fi
        if [[ $word != -* || ( $word == -* && $word != --* && $word == *c* ) ]]; then
          # A matching alias already names the script file; later words are
          # arguments to that script, not another script-file operand.
          (( alias_claimed )) || script_word=1
          break
        fi
      done
      (( stdout_sunk )) && continue
      (( script_word )) && continue
      (( reaches )) || continue
      if [[ ${quoted[op_index]} == *'<<<' ]]; then
        (( op_index + 1 < ${#quoted[@]} )) || continue
        payload=${quoted[op_index+1]}
      else
        payload=${quoted[op_index]#*'<<<'}
      fi
      words=()
      mapfile -t words < <(__lmline_risk_split_words "${payload//"$marker"/ }")
      ((${#words[@]})) || continue
      payload=${words[*]}
      [[ -n $payload ]] && printf '%s\n' "$payload"
    done
  done <<<"$(__lmline_split_pipeline "$cmd" 1)"
}

# A process substitution that supplies a shell's script, either as a `<` stdin
# redirect source or as the shell's script-file argument, is an implicit script
# input like a pipe to a shell. The structural splitter's unquoted view proves
# the operator is active; its quote-preserving view keeps the words around it,
# including a script word the unquoted view drops. No input is executed here.
__lmline_risk_generated_script_source() {
  local cmd=$1 segment marker word quoted_text scan
  local index cmd_index q_index source_index q_source script_word=0
  local alias_fd alias_matches numbered='^([0-9]+)<$' source_fd dup_target
  local -a plain=() quoted=()
  local IFS=$' \t\n'
  printf -v marker '\002'
  # The structural splitter reads & and | as command separators, even inside
  # redirection operators. Fold those operators into their base marker so
  # the shell word and its generated script stay in one structural segment.
  scan=${cmd//&\>/\>}
  scan=${scan//\>\|/\>}
  while IFS= read -r segment || [[ -n $segment ]]; do
    mapfile -t plain < <(__lmline_risk_split_words "$(__lmline_split_pipeline "$segment" 0 "" bash structural-substitution 0)")
    ((${#plain[@]})) || continue
    cmd_index=$(__lmline_risk_segment_command_index "${plain[@]}") || continue
    if ! __lmline_risk_word_runs_shell "${plain[cmd_index]}" &&
       ! __lmline_risk_word_sources_script "${plain[cmd_index]}"; then
      continue
    fi
    source_index=-1
    for ((index = cmd_index + 1; index < ${#plain[@]}; index++)); do
      if [[ ${plain[index]} == '<('* ]]; then
        source_index=$index
        break
      fi
    done
    (( source_index >= 0 )) || continue
    quoted_text=$(__lmline_split_pipeline "$segment" 2 "" bash structural-substitution 0)
    read -r -a quoted <<<"${quoted_text//"$marker"/ }"
    q_source=-1
    for ((index = 0; index < ${#quoted[@]}; index++)); do
      if [[ ${quoted[index]} == '<('* ]]; then
        q_source=$index
        break
      fi
    done
    (( q_source >= 0 )) || continue
    q_index=$(__lmline_risk_segment_command_index "${quoted[@]}") || continue
    (( q_index < q_source )) || continue
    if ! __lmline_risk_word_runs_shell "${quoted[q_index]}" &&
       ! __lmline_risk_word_sources_script "${quoted[q_index]}"; then
      continue
    fi
    # Only an input redirect immediately before the substitution feeds its
    # script: a bare '<' feeds stdin and '3<' feeds descriptor 3. An earlier
    # redirect with its own target is unrelated to this process substitution.
    source_fd=''
    if (( q_source > q_index )); then
      word=${quoted[q_source-1]}
      if [[ $word == '<' ]]; then
        source_fd=0
      elif [[ $word =~ $numbered ]]; then
        source_fd=$((10#${BASH_REMATCH[1]}))
      fi
    fi
    # A duplication after the substitution can also carry its script fd into
    # an alias; one before it copied the earlier input instead.
    __lmline_risk_carry_fds "$source_fd" $((q_source + 1)) "${quoted[@]}"
    # A command string or script file already gives the shell its script, so
    # the process substitution is only an argument to that program.
    script_word=0
    for ((index = q_index + 1; index < q_source; index++)); do
      word=${quoted[index]}
      alias_fd=$(__lmline_risk_stream_script_alias_descriptor "$word") || alias_fd=
      if [[ -n $alias_fd ]]; then
        alias_matches=0
        [[ -n $source_fd && $alias_fd == "$source_fd" ]] && alias_matches=1
        for dup_target in "${__LMLINE_RISK_CARRIED_FDS[@]}"; do
          [[ $alias_fd == "$dup_target" ]] && { alias_matches=1; break; }
        done
        (( alias_matches )) && continue
      fi
      # The process substitution itself is the script source, not a redirect
      # target or a script word.
      case $word in
        '<('*) continue ;;
      esac
      if __lmline_risk_redirect_word "$word"; then
        (( __LMLINE_RISK_REDIRECT_TARGET )) && index=$((index + 1))
        continue
      fi
      case $word in
        -o|-O|--rcfile|--init-file) index=$((index + 1)) ;;
        --*) ;;
        -*c*) script_word=1; break ;;
        -*) ;;
        *) script_word=1; break ;;
      esac
    done
    if (( script_word )); then continue; fi
    return 0
  done <<<"$(__lmline_split_pipeline "$scan" 1 "" bash structural-substitution 0)"
  return 1
}

# Risk precedence: structural recognition (piped shell, generated shell script
# source, interactive history, unresolved variable command, capped brace
# expansion, recursive remove) is mechanism only; its levels are configuration
# (LMLINE_RISK_*_LEVEL, defaults high/high/medium/medium/high; the generated
# script source shares the piped-shell level; unknown or empty falls back to
# the default).
# A replacement risk_patterns file overrides shipped patterns and structural
# defaults: with a user or explicit file, the first matching rule wins and
# structural fallbacks apply only when no rule matched. With the shipped
# default file, shipped patterns and structural fallbacks compete and the
# highest level wins, so a generic medium rule never shadows a structural
# high. LMLINE_RISK_*_LEVEL tunes structural fallbacks in both modes. Defaults
# stay protective.
# The strongest risk among nested command strings read from standard input.
# Each is judged by the same rules at the next bounded depth.
__lmline_risk_nested_best() {
  local depth=$1 payload match level rank best_level="" best_reason="" best_rank=0
  while IFS= read -r payload || [[ -n $payload ]]; do
    [[ -n $payload ]] || continue
    match=$(__lmline_risk_match "$payload" $((depth + 1))) || return 1
    [[ -n $match ]] || continue
    level=${match%%$'\t'*}
    rank=$(__lmline_risk_level_rank "$level")
    if (( rank > best_rank )); then
      best_rank=$rank
      best_level=$level
      best_reason=${match#*$'\t'}
    fi
  done
  if [[ -n $best_level ]]; then
    printf '%s\t%s\n' "$best_level" "$best_reason"
  fi
  return 0
}

__lmline_risk_match() {
  local cmd=$1 depth=${2:-0} expanded file line level pattern reason alt bare_alt decoded_alt operand_alt neutral_alt signal_alt canon alts_str
  local brace_capped=0 best_level="" best_reason="" piped_found=0 generated_found=0 history_found=0
  local removal_found=0 removal_reason="recursive remove"
  local shipped_defaults=0
  local struct_level="" struct_reason="" struct_rank=0 rank candidate_level best_rank=0
  local nested_match nested_level
  # History is judged on raw quoting/escaping, never decoded/canonical text.
  if __lmline_risk_history_expansion "$cmd"; then history_found=1; fi
  # Decode ANSI-C quoting so hex/octal hides are judged by content.
  expanded=$(__lmline_decode_ansi_c_for_risk "$cmd")
  # A here-string handed to a shell command word is a nested script. Judge it
  # with these same rules at a bounded depth; its level competes with the
  # other structural signals below under the usual precedence.
  if (( depth < 3 )) && [[ $expanded == *'<<<'* ]]; then
    nested_match=$(__lmline_risk_nested_best "$depth" < <(__lmline_risk_here_string_payload "$expanded")) || return 1
    if [[ -n $nested_match ]]; then
      nested_level=${nested_match%%$'\t'*}
      rank=$(__lmline_risk_level_rank "$nested_level")
      if (( rank > struct_rank )); then
        struct_rank=$rank
        struct_level=$nested_level
        struct_reason=${nested_match#*$'\t'}
      fi
    fi
  fi
  # A shell runs its -c argument as a command string. Judge those strings
  # with these same rules at a bounded depth, including strings supplied by a
  # substitution in command position.
  if (( depth < 3 )); then
    nested_match=$(__lmline_risk_nested_best "$depth" < <(__lmline_risk_shell_c_command_strings_in "$expanded")) || return 1
    if [[ -n $nested_match ]]; then
      nested_level=${nested_match%%$'\t'*}
      rank=$(__lmline_risk_level_rank "$nested_level")
      if (( rank > struct_rank )); then
        struct_rank=$rank
        struct_level=$nested_level
        struct_reason=${nested_match#*$'\t'}
      fi
    fi
  fi
  # A substitution in command position supplies the command string itself.
  # Judge the data it can hand back with these same rules at a bounded depth.
  if (( depth < 3 )) && __lmline_risk_substitution_in_command_position "$expanded"; then
    nested_match=$(__lmline_risk_nested_best "$depth" < <(__lmline_risk_substitution_command_payloads "$expanded")) || return 1
    if [[ -n $nested_match ]]; then
      nested_level=${nested_match%%$'\t'*}
      rank=$(__lmline_risk_level_rank "$nested_level")
      if (( rank > struct_rank )); then
        struct_rank=$rank
        struct_level=$nested_level
        struct_reason=${nested_match#*$'\t'}
      fi
    fi
  fi
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
  # Whether the shipped rules are in force, decided once: the scan below
  # reads the file, so the file itself is not named inside the scan.
  shipped_defaults=0
  if [[ "$file" == "$LMLINE_DEFAULTS_DIR/risk_patterns.tsv" ]]; then
    shipped_defaults=1
  fi
  while IFS= read -r alt || [[ -n $alt ]]; do
    # Normalize: canonicalize quoting/IFS/braces, squeeze whitespace, and
    # wrap in single spaces so one pattern like "* dd *" matches at line
    # start, mid-pipeline, and bare. Structural pipe-to-shell recognition
    # is recorded here and decided after pattern matching (see the
    # precedence note above): a replacement rule can override it, while
    # shipped defaults compete with it for the highest level.
    if __lmline_risk_piped_shell "$alt"; then
      piped_found=1
    fi
    if __lmline_risk_generated_script_source "$alt"; then
      generated_found=1
    fi
    if __lmline_risk_recursive_remove "$alt"; then
      removal_found=1
    fi
    # Reduce command names first, then decode and canonicalize each segment:
    # the flat view has no separators left to tell commands apart.
    bare_alt=$(__lmline_risk_basename_command_words "$alt")
    operand_alt=$(__lmline_risk_neutralize_find_delete_operand "$bare_alt")
    decoded_alt=$(__lmline_risk_map_segments "$operand_alt" __lmline_risk_decode_segment_for_risk)
    neutral_alt=$(__lmline_risk_neutralize_flags_after_double_dash "$decoded_alt")
    signal_alt=$(__lmline_risk_map_segments "$neutral_alt" __lmline_risk_canonicalize_kill_signal)
    canon=$(__lmline_canonicalize_for_risk <<<"$signal_alt" | tr -s '[:space:]' ' ')
    canon=${canon# }
    canon=${canon% }
    canon=" $canon "
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      IFS=$'\t' read -r level pattern reason <<<"$line"
      [[ -n "$level" && -n "$pattern" ]] || continue
      case "$level" in high|medium|low) ;; *) continue ;; esac
      # SC2053: a policy rule pattern is a glob and must stay unquoted.
      # shellcheck disable=SC2053
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
  if (( piped_found || generated_found )); then
    candidate_level=$(__lmline_risk_structural_level "${LMLINE_RISK_PIPED_SHELL_LEVEL:-high}" high)
    rank=$(__lmline_risk_level_rank "$candidate_level")
    if (( rank > struct_rank )); then
      struct_rank=$rank
      struct_level=$candidate_level
      if (( generated_found && ! piped_found )); then
        struct_reason="generated shell script execution"
      else
        struct_reason="piped shell execution"
      fi
    fi
  fi
  if (( history_found )); then
    candidate_level=$(__lmline_risk_structural_level "${LMLINE_RISK_HISTORY_EXPANSION_LEVEL:-high}" high)
    rank=$(__lmline_risk_level_rank "$candidate_level")
    if (( rank > struct_rank )); then
      struct_rank=$rank
      struct_level=$candidate_level
      struct_reason="interactive history expansion"
    fi
  fi
  if __lmline_risk_has_unresolved_var_command "$expanded"; then
    candidate_level=$(__lmline_risk_structural_level "${LMLINE_RISK_UNRESOLVED_VAR_LEVEL:-medium}" medium)
    rank=$(__lmline_risk_level_rank "$candidate_level")
    if (( rank > struct_rank )); then
      struct_rank=$rank
      struct_level=$candidate_level
      struct_reason="unresolved variable command"
    fi
  fi
  if (( brace_capped )); then
    candidate_level=$(__lmline_risk_structural_level "${LMLINE_RISK_BRACE_CAPPED_LEVEL:-medium}" medium)
    rank=$(__lmline_risk_level_rank "$candidate_level")
    if (( rank > struct_rank )); then
      struct_rank=$rank
      struct_level=$candidate_level
      struct_reason="unresolved brace expansion"
    fi
  fi
  if (( removal_found )); then
    candidate_level=$(__lmline_risk_structural_level "${LMLINE_RISK_RECURSIVE_REMOVE_LEVEL:-high}" high)
    rank=$(__lmline_risk_level_rank "$candidate_level")
    if (( rank > struct_rank )); then
      struct_rank=$rank
      struct_level=$candidate_level
      struct_reason=$removal_reason
    fi
  fi
  if [[ "$shipped_defaults" == 1 ]]; then
    # Shipped defaults compete: highest wins so a generic medium rule never
    # shadows a structural high (for example c{p,url} with *cp *).
    if [[ -n $best_level && -n $struct_level ]]; then
      best_rank=$(__lmline_risk_level_rank "$best_level")
      if (( struct_rank >= best_rank )); then
        printf '%s\t%s\n' "$struct_level" "$struct_reason"
      else
        printf '%s\t%s\n' "$best_level" "$best_reason"
      fi
      return 0
    fi
    if [[ -n $struct_level ]]; then
      printf '%s\t%s\n' "$struct_level" "$struct_reason"
      return 0
    fi
    if [[ -n $best_level ]]; then
      printf '%s\t%s\n' "$best_level" "$best_reason"
      return 0
    fi
  else
    # Replacement file overrides: a matching rule wins over structural
    # fallbacks, which apply only when no rule matched.
    if [[ -n $best_level ]]; then
      printf '%s\t%s\n' "$best_level" "$best_reason"
      return 0
    fi
    if [[ -n $struct_level ]]; then
      printf '%s\t%s\n' "$struct_level" "$struct_reason"
      return 0
    fi
  fi
}

# Fail-closed net for variable indirection in the command word ($VAR, ${VAR},
# or surviving $'...' residue): the value cannot be proven safe, so report
# the configured LMLINE_RISK_UNRESOLVED_VAR_LEVEL (default medium) and let
# the insert warning and fix-mode gating apply. Concrete words
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

# Recognize only one plain single-quoted eval argument, with no concatenation,
# extra arguments or redirections. Unsupported/dynamic forms remain opaque (2).
# Single quotes need no decoding: their contents are passed only to syntax-only
# parsing and the availability extractor, never to eval or an executing shell.
__lmline_extract_literal_eval_words() {
  local remaining=$1 shell=$2 functions=${3:-} inner
  local literal="^[[:blank:]]+'([^']*)'[[:blank:]]*($|[;&|)"$'\n'"])"
  local comment_literal="^[[:blank:]]+'([^']*)'[[:blank:]]+#"
  if [[ "$remaining" =~ $literal ]]; then
    inner=${BASH_REMATCH[1]}
  elif [[ "$remaining" =~ $comment_literal ]]; then
    inner=${BASH_REMATCH[1]}
  else
    return 2
  fi
  if [[ "$shell" == zsh ]]; then
    __lmline_zsh_syntax_probe "$inner" || return 1
  else
    "$BASH" -p -n -c "$inner" >/dev/null 2>&1 || return 1
  fi
  # A trailing analysis-only newline commits an adjacent remover call too.
  # Return words and surviving input bindings separately; neither is executable.
  __lmline_extract_command_words "$inner"$'\n' "$shell" 1 "$functions" "${4:-}" "${5:-}"
}

# Recognize only one plain single-quoted trap action followed by at least one
# signal word, with no options, concatenation or wrappers. Unsupported/dynamic
# forms (including double quotes, missing signals and option/wrapper positions)
# remain opaque (2). Single quotes need no decoding: their contents are passed
# only to syntax-only parsing and the availability extractor, never to an
# executing shell.
__lmline_extract_literal_trap_words() {
  local remaining=$1 shell=$2 functions=${3:-} inner rest after
  local literal_trap_words literal_trap_functions trap_without_callers="" trap_active_callers="" trap_name trap_probe_words
  local prefix="^[[:blank:]]+'([^']*)'"
  # Only plain EXIT/0 triggers are known to run after the candidate. Mixed,
  # dynamic or other signal lists are conservatively early; no scheduling.
  local exit_signals="^[[:blank:]]+(EXIT|0)([[:blank:]]+(EXIT|0))*([[:blank:]]*($|[;&|)"$'\n'"])|[[:blank:]]+#)"
  [[ "$remaining" =~ $prefix ]] || return 2
  inner=${BASH_REMATCH[1]}
  rest=${remaining:${#BASH_REMATCH[0]}}
  [[ "$rest" =~ ^[[:blank:]]+([^[:blank:]]) ]] || return 2
  after=${BASH_REMATCH[1]}
  case "$after" in
    ';'|'|'|'&'|'('|')'|'#'|'<'|'>') return 2 ;;
  esac
  if [[ "$inner" =~ ^[[:blank:]]*(-)?[[:blank:]]*$ ]]; then
    printf -v "$4" '%s' ""
    printf -v "$5" '%s' "$functions"
    return 0
  fi
  if [[ "$shell" == zsh ]]; then
    __lmline_zsh_syntax_probe "$inner" || return 1
  else
    "$BASH" -p -n -c "$inner" >/dev/null 2>&1 || return 1
  fi
  # Reuse the action's surviving bindings, but never treat registration-time
  # caller-only state as proof of what a delayed action can call. Explicit
  # candidate definitions retain their provenance even on a transport collision.
  # A syntax-only scan without caller-only bindings exposes command positions
  # (not argument text); action declarations still provide their own bindings.
  __lmline_extract_command_words "$inner"$'\n' "$shell" 1 "$functions" literal_trap_words literal_trap_functions || return 1
  while IFS= read -r trap_name; do
    [[ -n "$trap_name" ]] || continue
    if [[ $'\n'"${__lmline_trap_caller_functions-}"$'\n' == *$'\n'"$trap_name"$'\n'* && $'\n'"${__lmline_candidate_defined_functions-}"$'\n' != *$'\n'"$trap_name"$'\n'* ]]; then
      trap_active_callers+=$'\n'"$trap_name"$'\n'
    else
      trap_without_callers+=$'\n'"$trap_name"$'\n'
    fi
  done <<<"$functions"
  if [[ -n "$trap_active_callers" ]]; then
    trap_probe_words=$(__lmline_extract_command_words "$inner"$'\n' "$shell" 1 "$trap_without_callers") || return 1
    while IFS= read -r trap_name; do
      [[ -n "$trap_name" ]] || continue
      [[ $'\n'"$trap_active_callers"$'\n' != *$'\n'"$trap_name"$'\n'* ]] || return 1
    done <<<"$trap_probe_words"
  fi
  # EXIT-only removal cannot invalidate earlier candidate commands. For any
  # other trigger return surviving input bindings, never action-local additions:
  # the caller intersects this with its own current state, not the transport.
  [[ ! "$rest" =~ $exit_signals ]] || literal_trap_functions=$functions
  printf -v "$4" '%s' "$literal_trap_words"
  printf -v "$5" '%s' "$literal_trap_functions"
}

# Recognize direct `bash [-euvx] -c '…'` and `zsh -f -c '…'` with a
# single statically single-quoted script argument and no wrappers,
# concatenation or trailing operands. Bash's no-argument -e, -u, -v and -x
# flags may appear separately or clustered before -c; other options remain
# opaque (2). Single quotes need no decoding: their contents are passed only
# to syntax-only parsing and the availability extractor, never to an executing
# shell. The script is parsed and checked with the invoked shell's parser and
# command vocabulary, so a zsh-only builtin inside `zsh -f -c` is available
# even when the outer candidate targets bash. Outer function definitions do
# not leak into the new shell process; definitions inside the script itself
# are handled by its own availability scan. Unexported caller-shell functions
# and aliases are not visible to the new process either; only commands the
# invoked shell itself resolves (its builtins, PATH lookups and inherited
# exported functions) count as available.
__lmline_extract_literal_shell_c_words() {
  local token=$1 remaining=$2 functions=${3:-} outer_shell=${4:-bash}
  local inherited_bindings=${5-$functions} inner inner_shell words word syntax_status=0
  local inherited_exports=${__lmline_exported_functions-} __lmline_exported_functions="" inner_functions=""
  # The child inherits the cwd at this command position. Carry uncertainty,
  # never a candidate directory value, into its recursive availability scan.
  local __lmline_cwd_uncertain=${6:-0}
  # Only unchanged inherited bindings cross a process boundary. The names are
  # scan-local data; no candidate definition or function body is transported.
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    if [[ "$outer_shell" != bash || $'\n'"$inherited_bindings"$'\n' == *$'\n'"$word"$'\n'* ]]; then
      __lmline_exported_functions+=$'\n'"$word"$'\n'
    fi
  done <<<"$inherited_exports"
  # A new shell has no transported caller bindings, including in its traps.
  local __lmline_trap_caller_functions="" __lmline_candidate_defined_functions=""
  local bash_literal="^([[:blank:]]+-[euvx]+)*[[:blank:]]+-c[[:blank:]]+'([^']*)'[[:blank:]]*($|[;&|)])"
  local bash_comment="^([[:blank:]]+-[euvx]+)*[[:blank:]]+-c[[:blank:]]+'([^']*)'[[:blank:]]+#"
  local zsh_literal="^[[:blank:]]+-f[[:blank:]]+-c[[:blank:]]+'([^']*)'[[:blank:]]*($|[;&|)"$'\n'"])"
  local zsh_comment="^[[:blank:]]+-f[[:blank:]]+-c[[:blank:]]+'([^']*)'[[:blank:]]+#"
  if [[ $'\n'"$functions"$'\n' == *$'\n'"$token"$'\n'* ]]; then
    return 2
  fi
  if [[ "$token" == bash ]]; then
    inner_shell=bash
    if [[ "$remaining" =~ $bash_literal ]]; then
      inner=${BASH_REMATCH[2]}
    elif [[ "$remaining" =~ $bash_comment ]]; then
      inner=${BASH_REMATCH[2]}
    else
      return 2
    fi
  elif [[ "$token" == zsh ]]; then
    inner_shell=zsh
    if [[ "$remaining" =~ $zsh_literal ]]; then
      inner=${BASH_REMATCH[1]}
    elif [[ "$remaining" =~ $zsh_comment ]]; then
      inner=${BASH_REMATCH[1]}
    else
      return 2
    fi
  else
    return 2
  fi
  if [[ "$inner_shell" == zsh ]]; then
    __lmline_zsh_syntax_probe "$inner" || syntax_status=$?
    case $syntax_status in
      0) ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  else
    "$BASH" -p -n -c "$inner" >/dev/null 2>&1 || return 1
  fi
  [[ "$inner_shell" != bash ]] || inner_functions=$__lmline_exported_functions
  words=$(__lmline_extract_command_words "$inner" "$inner_shell" 1 "$inner_functions") || return 1
  if [[ "$inner_shell" == bash ]]; then
    local -a bash_words=()
    while IFS= read -r word; do
      [[ -n "$word" ]] || continue
      [[ "$word" == */* ]] && continue
      __lmline_word_is_policy_skip "$word" && continue
      bash_words+=("$word")
    done <<<"$words"
    __lmline_words_available_in_bash ${bash_words[@]+"${bash_words[@]}"} || return 1
    return 0
  fi
  local -a zsh_words=()
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    [[ "$word" == */* ]] && continue
    __lmline_word_is_policy_skip "$word" && continue
    zsh_words+=("$word")
  done <<<"$words"
  __lmline_words_available_in_zsh ${zsh_words[@]+"${zsh_words[@]}"} || return 1
  return 0
}

# shellcheck source=lmline/policy-parse.bash
source "$__LMLINE_POLICY_DIR/policy-parse.bash"
