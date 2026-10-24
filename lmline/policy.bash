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
  case "${1##*/}" in
    chroot|flock|su) printf '1\n' ;;
    '!'|busybox|builtin|command|doas|env|exec|ionice|nice|nohup|screen|script|setsid|stdbuf|sudo|systemd-run|taskset|time|timeout|tmux|toybox|unshare|watch|xargs) printf '0\n' ;;
  esac
  return 0
}

# Whether a word names a program that runs another program.
__lmline_risk_is_runner() {
  [[ -n $(__lmline_risk_runner_operands "$1") ]]
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
  __lmline_clamp_int max_len 4096 0 1
  byte_len=$(LC_ALL=C printf '%s' "$cmd" | wc -c)
  (( byte_len > max_len ))
}

__lmline_truncate_candidate() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096}
  __lmline_clamp_int max_len 4096 0 1
  printf '%s' "$cmd" | LC_ALL=C cut -c "1-$max_len"
}

__lmline_truncated_comment_candidate() {
  local cmd=$1 max_len=${LMLINE_MAX_CANDIDATE_BYTES:-4096} prefix="# TRUNCATED: " prefix_len body_len
  __lmline_clamp_int max_len 4096 0 1
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
  local cmd=$1 mode=${2:-} shell=${3:-bash}
  [[ $(__lmline_candidate_rejection_reason "$cmd" "$mode" "$shell") == ok ]]
}

__lmline_candidate_rejection_reason() {
  local cmd=$1 mode=${2:-} shell=${3:-bash}
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
  if [[ "$shell" == zsh ]]; then
    command -v zsh >/dev/null 2>&1 || { printf 'shell-validator-unavailable'; return 0; }
    command zsh -f -n -c "$cmd" >/dev/null 2>&1 || { printf 'shell-syntax'; return 0; }
  else
    bash -n -c "$cmd" >/dev/null 2>&1 || { printf 'shell-syntax'; return 0; }
  fi
  __lmline_reject_env_only_pipeline "$cmd" "$shell" || { printf 'env-only-command-segment'; return 0; }
  __lmline_reject_directory_file_operands "$cmd" || { printf 'directory-file-operand'; return 0; }
  __lmline_validate_commands_available "$cmd" "$shell" || { printf 'command-not-found'; return 0; }
  printf 'ok'
}

__lmline_split_pipeline() {
  local cmd=$1 keep_quoted=${2:-0} extra_seps=${3:-} syntax_shell=${4:-bash} split_mode=${5:-all}
  local stripped="" i ch next quote="" prev="" zsh_glob_qualifier_depth=0 zsh_qualifier_just_closed=0 prior_zsh_qualifier_close
  for ((i = 0; i < ${#cmd}; i++)); do
    ch=${cmd:i:1}
    next=${cmd:i+1:1}
    prior_zsh_qualifier_close=$zsh_qualifier_just_closed
    zsh_qualifier_just_closed=0
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
      '|'|';'|'&')
        # Inside an open zsh glob qualifier a separator is part of the word
        # (*(e:echo hi|cat:) is one glob), so it does not split there.
        if [[ "$syntax_shell" == zsh ]] && (( zsh_glob_qualifier_depth > 0 )); then
          stripped+=$ch
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
  stripped=$(__lmline_split_pipeline "$cmd" 0 "" "$syntax_shell" env-pipeline)

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
  local cmd=$1 stripped segment token word base first_base cmd_index
  local -a words subs
  stripped=$(__lmline_split_pipeline "$cmd" 1)
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
      if (( ansi )) && [[ $ch == '\' ]]; then
        i=$((i + 1))
      elif [[ $ch == "'" ]]; then
        quote=""
        ansi=0
      fi
      continue
    fi
    case "$ch" in
      '\') i=$((i + 1)) ;;
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
        (( i == 0 )) || [[ ${cmd:i-1:1} != '\' ]] || continue
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
  local str=$1 word="" ch quote="" i n
  n=${#str}
  for ((i = 0; i < n; i++)); do
    ch=${str:i:1}
    if [[ -n "$quote" ]]; then
      if [[ "$quote" == '"' && "$ch" == '\\' ]]; then
        i=$((i + 1))
        word+=${str:i:1}
        continue
      fi
      if [[ "$ch" == "$quote" ]]; then
        quote=""
        continue
      fi
      word+=$ch
      continue
    fi
    case "$ch" in
      "'"|'"'|'`')
        quote=$ch
        ;;
      '\\')
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

# Whether a word runs a shell. The word is read as the words it runs, with
# the quoting removed and the expansions spaced, so a spelling that hides the
# command is read as the words it runs.
__lmline_risk_word_runs_shell() {
  local canonical base
  local -a canon=()
  canonical=$(__lmline_canonicalize_for_risk <<<"$1")
  [[ -n $canonical ]] || return 1
  read -r -a canon <<<"$canonical" || true
  ((${#canon[@]} > 0)) || return 1
  base=${canon[0]##*/}
  __lmline_word_is_shell "$base"
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

# The command a program that runs another program runs: the first word that
# is not one of the program's own options, not the value one of those
# options takes, and not an operand the program names for itself. A remove
# or a shell in that position is the command the program runs, whatever the
# option before it names.
__lmline_risk_carried_command_index() {
  local -a words=("$@")
  local index word base expect_value=0
  local operands_left
  operands_left=$(__lmline_risk_runner_operands "${words[0]}")
  for (( index = 1; index < ${#words[@]}; index++ )); do
    word=${words[index]}
    [[ "$word" == *=* ]] && continue
    if [[ "$word" == -* ]]; then
      expect_value=1
      continue
    fi
    base=${word##*/}
    if __lmline_risk_word_is_remove_command "$word" || __lmline_word_is_shell "$base"; then
      printf '%s\n' "$index"
      return 0
    fi
    if (( expect_value )); then
      expect_value=0
      continue
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
  local -a words=("$@")
  local index=0 word base cmd_index
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
      cmd_index=$(__lmline_risk_carried_command_index "${words[@]:index}") || return 1
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
__lmline_risk_shell_carries_remove() {
  local depth=$1
  shift
  local word cluster carried index count=$# expect_value=0
  local -a shell_args=("$@")
  for (( index = 0; index < count; index++ )); do
    word=${shell_args[index]}
    if [[ "$word" == -* ]]; then
      if [[ "$word" == --* ]]; then
        # A long option is never the -c option, and it takes a value.
        expect_value=1
        continue
      fi
      cluster=${word#-}
      case "$cluster" in
        *c*)
          carried=${cluster#*c}
          if [[ -n $carried ]]; then
            # The string is written into the option itself, so the words that
            # follow it belong to it.
            while (( index + 1 < count )); do
              index=$((index + 1))
              carried+=" ${shell_args[index]}"
            done
          elif (( index + 1 < count )); then
            index=$((index + 1))
            carried=${shell_args[index]}
          fi
          [[ -n $carried ]] || return 1
          __lmline_risk_recursive_remove "$carried" $((depth + 1)) && return 0
          return 1
          ;;
      esac
      # The option that names the shell's own settings takes a value.
      expect_value=0
      [[ "$word" == -o || "$word" == -O ]] && expect_value=1
      continue
    fi
    # The value of the option before it belongs to the shell; any other word
    # is the script the shell runs.
    (( expect_value )) || return 1
    expect_value=0
  done
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
  local count cmd_index
  local -a words
  (( depth < 4 )) || return 1
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
    cmd_index=$(__lmline_risk_segment_command_index "${words[@]}") || continue
    word=${words[cmd_index]}
    if __lmline_risk_word_runs_shell "$word"; then
      # A shell command word runs the command string it is given after -c.
      __lmline_risk_shell_carries_remove $((depth + 1)) "${words[@]:cmd_index+1}" && return 0
      continue
    fi
    # The command the segment runs. Its own flags follow it, so the words
    # after it are read as the flags it writes.
    __lmline_risk_remove_word_is_recursive "$word" "${words[@]:cmd_index+1}" && return 0
  done <<<"$(__lmline_split_pipeline "$cmd" 1 "()")"
  return 1
}

# Risk precedence: structural recognition (piped shell, interactive history,
# unresolved variable command, capped brace expansion, recursive remove) is
# mechanism only; its levels are configuration (LMLINE_RISK_*_LEVEL, defaults
# high/high/medium/medium/high; unknown or empty falls back to the default).
# A replacement risk_patterns file overrides shipped patterns and structural
# defaults: with a user or explicit file, the first matching rule wins and
# structural fallbacks apply only when no rule matched. With the shipped
# default file, shipped patterns and structural fallbacks compete and the
# highest level wins, so a generic medium rule never shadows a structural
# high. LMLINE_RISK_*_LEVEL tunes structural fallbacks in both modes. Defaults
# stay protective.
__lmline_risk_match() {
  local cmd=$1 expanded file line level pattern reason alt canon alts_str
  local brace_capped=0 best_level="" best_reason="" piped_found=0 history_found=0
  local removal_found=0 removal_reason="recursive remove"
  local shipped_defaults=0
  local struct_level="" struct_reason="" struct_rank=0 rank candidate_level best_rank=0
  # History is judged on raw quoting/escaping, never decoded/canonical text.
  if __lmline_risk_history_expansion "$cmd"; then history_found=1; fi
  # Decode ANSI-C quoting so hex/octal hides are judged by content.
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
    if __lmline_risk_recursive_remove "$alt"; then
      removal_found=1
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
  if (( piped_found )); then
    candidate_level=$(__lmline_risk_structural_level "${LMLINE_RISK_PIPED_SHELL_LEVEL:-high}" high)
    rank=$(__lmline_risk_level_rank "$candidate_level")
    if (( rank > struct_rank )); then
      struct_rank=$rank
      struct_level=$candidate_level
      struct_reason="piped shell execution"
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
    command zsh -f -n -c "$inner" >/dev/null 2>&1 || return 1
  else
    bash -n -c "$inner" >/dev/null 2>&1 || return 1
  fi
  __lmline_extract_command_words "$inner" "$shell" 1 "$functions"
}

# Recognize only one plain single-quoted trap action followed by at least one
# signal word, with no options, concatenation or wrappers. Unsupported/dynamic
# forms (including double quotes, missing signals and option/wrapper positions)
# remain opaque (2). Single quotes need no decoding: their contents are passed
# only to syntax-only parsing and the availability extractor, never to an
# executing shell.
__lmline_extract_literal_trap_words() {
  local remaining=$1 shell=$2 functions=${3:-} inner rest after
  local prefix="^[[:blank:]]+'([^']*)'"
  [[ "$remaining" =~ $prefix ]] || return 2
  inner=${BASH_REMATCH[1]}
  rest=${remaining:${#BASH_REMATCH[0]}}
  [[ "$rest" =~ ^[[:blank:]]+([^[:blank:]]) ]] || return 2
  after=${BASH_REMATCH[1]}
  case "$after" in
    ';'|'|'|'&'|'('|')'|'#'|'<'|'>') return 2 ;;
  esac
  if [[ "$inner" =~ ^[[:blank:]]*(-)?[[:blank:]]*$ ]]; then
    return 0
  fi
  if [[ "$shell" == zsh ]]; then
    command zsh -f -n -c "$inner" >/dev/null 2>&1 || return 1
  else
    bash -n -c "$inner" >/dev/null 2>&1 || return 1
  fi
  __lmline_extract_command_words "$inner" "$shell" 1 "$functions"
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
  local token=$1 remaining=$2 functions=${3:-} inner inner_shell words word
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
    command -v zsh >/dev/null 2>&1 || return 2
    command zsh -f -n -c "$inner" >/dev/null 2>&1 || return 1
  else
    command bash -n -c "$inner" >/dev/null 2>&1 || return 1
  fi
  words=$(__lmline_extract_command_words "$inner" "$inner_shell" 1 "") || return 1
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    [[ "$word" == */* ]] && continue
    __lmline_word_is_policy_skip "$word" && continue
    if [[ "$inner_shell" == zsh ]]; then
      __lmline_word_available_in_zsh "$word" && continue
      return 1
    else
      __lmline_word_available_in_bash "$word" || return 1
    fi
  done <<<"$words"
  return 0
}

# Make an availability-only copy with case/function/static Zsh loop headers
# removed, not bodies.
# Definitions inside conditional (if), case-branch, loop or subshell bodies
# are scoped to that body and never leak past their control flow.
# Token boundaries, quotes and escapes distinguish syntax from arguments. A
# stack keeps nested cases independent; pattern parentheses do not open bodies.
# Substitutions are checked recursively, including those inside quoted selectors.
# The target shell's syntax-only parser finds their closing delimiter, so nested
# substitutions and case-pattern ')' characters cannot truncate the check.
# The literal-only mode collects literal eval/trap/shell-c words without rewriting outer
# syntax or broadening substitution checks; status 2 marks a recognized invalid literal.
__lmline_case_command_copy() {
  local cmd=$1 shell=$2 only_substitutions=${3:-0} functions=${4:-} only_literal_evals=${5:-0} out="" substitutions=""
  local name header remaining zsh_for_words eval_status trap_status shellc_status
  local function_header='^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*(\([[:space:]]*\)[[:space:]]*)?\{([[:space:]]|$)'
  local paren_header='^[[:space:]]*\([[:space:]]*\)[[:space:]]*\{([[:space:]]|$)'
  local function_name='^[a-zA-Z_][a-zA-Z0-9_]*$'
  local paren_signature='^[[:space:]]*\([[:space:]]*\)'
  local zsh_for_prefix='^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*[(]'
  local zsh_for_header='^[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*[(](([^()]|[(][^()]*[)])*)[)]'
  local coproc_compound_keywords='!|if|for|while|until|case|select|time|function|coproc'
  [[ "$shell" != zsh ]] || coproc_compound_keywords+='|repeat'
  local coproc_named_compound='^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\{|\[|\()|^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+('"$coproc_compound_keywords"')([[:space:];]|$)'
  local i=0 start ch next token quote end fragment inner words word scope_idx compound_end=0 previous_compound_end
  local zsh_unscoped_loop_seen=0 zsh_repeat_count_pending=0
  local depth=0 command_start=1 pattern_started=0 pattern_depth=0
  local if_pending=0 elif_pending=0 brace_depth=0
  # Definitions in and/or lists or pipelines need control-flow reasoning.
  # Conservatively fail closed for those lists rather than evaluating their
  # conditions or depending on the shell's last-pipeline-member options.
  # Brace bodies get independent list state, so ordinary pipelines inside a
  # function do not make an otherwise direct definition unavailable.
  local -a list_operator=(0) list_definition=(0) brace_definition=(0)
  local -a state=(body) scope_saved=() scope_kind=()
  while (( i < ${#cmd} )); do
    ch=${cmd:i:1}
    if [[ "$ch" == [[:space:]] ]]; then
      out+=$ch
      [[ "$ch" != $'\n' ]] || command_start=1
      i=$((i + 1))
      continue
    fi
    # A comment starts only at an unquoted token boundary. Do not scan its
    # apparent headers, separators or substitutions as executable syntax.
    if [[ "$ch" == '#' ]]; then
      while (( i < ${#cmd} )) && [[ ${cmd:i:1} != $'\n' ]]; do
        i=$((i + 1))
      done
      continue
    fi
    start=$i
    case "$ch" in
      ';'|'|'|'&'|'('|')')
        token=$ch
        next=${cmd:i+1:1}
        if [[ "$ch$next" == ';;' || "$ch$next" == ';&' || "$ch$next" == ';|' || "$ch$next" == '&&' || "$ch$next" == '||' ]]; then
          token+=$next
          i=$((i + 1))
          if [[ "$token" == ';;' && ${cmd:i+1:1} == '&' ]]; then
            token+='&'
            i=$((i + 1))
          fi
        fi
        i=$((i + 1))
        ;;
      *)
        quote=""
        while (( i < ${#cmd} )); do
          ch=${cmd:i:1}
          next=${cmd:i+1:1}
          if [[ "$quote" != "'" && "$ch" == '\' ]]; then
            i=$((i + 2))
            continue
          fi
          if [[ "$quote" != "'" && ( "$ch$next" == '$(' || "$ch" == '`' ) ]]; then
            # Parse only: never expand or execute the fragment. The wrapper's
            # double quotes also work for substitutions in double-quoted words.
            end=$((i + 1))
            while (( end < ${#cmd} )); do
              if [[ ( "$ch" == '$' && ${cmd:end:1} == ')' ) || ( "$ch" == '`' && ${cmd:end:1} == '`' ) ]]; then
                fragment=${cmd:i:end-i+1}
                if [[ "$shell" == zsh ]]; then
                  command zsh -f -n -c ": \"$fragment\"" >/dev/null 2>&1 && break
                else
                  bash -n -c ": \"$fragment\"" >/dev/null 2>&1 && break
                fi
              fi
              end=$((end + 1))
            done
            (( end < ${#cmd} )) || return 1
            if (( only_literal_evals )); then
              # An eval-only scan must not broaden checking of dynamic or
              # unsupported outer arguments. Their substitutions stay opaque.
              i=$((end + 1))
              continue
            fi
            if [[ ${fragment:0:3} == '$((' ]]; then
              inner=${fragment:3:${#fragment}-5}
              words=$(__lmline_case_command_copy "$inner" "$shell" 1 "$functions") || return 1
              substitutions+=$words
            else
              if [[ "$ch" == '$' ]]; then
                inner=${fragment:2:${#fragment}-3}
              else
                inner=${fragment:1:${#fragment}-2}
                # Escaped nested backticks need another unquoting pass. Leave
                # such unsupported forms closed rather than dropping commands.
                [[ "$inner" != *'\`'* ]] || return 1
              fi
              words=$(__lmline_extract_command_words "$inner" "$shell" 1 "$functions") || return 1
              while IFS= read -r word; do
                [[ -z "$word" ]] || substitutions+="; $word "
              done <<<"$words"
            fi
            i=$((end + 1))
            continue
          fi
          if [[ -n "$quote" ]]; then
            [[ "$ch" != "$quote" ]] || quote=""
          else
            case "$ch" in
              "'"|'"') quote=$ch ;;
              [[:space:]]|';'|'|'|'&'|'('|')') break ;;
            esac
          fi
          i=$((i + 1))
        done
        token=${cmd:start:i-start}
        ;;
    esac
    previous_compound_end=$compound_end
    compound_end=0
    case "${state[depth]}" in
      selector) state[depth]=in ;;
      in)
        [[ "$token" == in ]] || return 1
        state[depth]=pattern
        pattern_started=0
        pattern_depth=0
        ;;
      pattern)
        case "$token" in
          "esac")
            (( pattern_started == 0 )) || return 1
            depth=$((depth - 1))
            out+=' '
            command_start=0
            compound_end=1
            ;;
          '(')
            (( pattern_started == 0 )) || pattern_depth=$((pattern_depth + 1))
            pattern_started=1
            ;;
          ')')
            if (( pattern_depth > 0 )); then
              pattern_depth=$((pattern_depth - 1))
            else
              state[depth]=body
              command_start=1
              out+='; '
              # A case branch body is conditional: definitions inside are
              # visible only within that branch, never after the case.
              scope_saved+=("$functions")
              scope_kind+=("case-branch")
            fi
            ;;
          *) pattern_started=1 ;;
        esac
        ;;
      body)
        # Recognize only static, brace-bodied definitions at command boundaries.
        # Consuming the header (including its opening brace) leaves every body
        # command visible. Names are local to this scan, not installed in a shell;
        # recursive substitution scans inherit them but cannot add names here.
        name=""
        remaining=${cmd:i}
        if (( command_start )) && [[ "$shell" == zsh && "$token" == for && "$remaining" =~ $zsh_for_prefix ]]; then
          # Track every short form, including dynamic lists whose substitutions
          # remain visible to the recursive availability scan below.
          zsh_unscoped_loop_seen=1
        fi
        if (( command_start )) && [[ "$token" == function ]]; then
          [[ "$remaining" =~ $function_header ]] || return 1
          header=${BASH_REMATCH[0]}
          name=${BASH_REMATCH[1]}
        elif (( command_start )) && [[ "$remaining" =~ $paren_signature ]]; then
          # Other names/body forms need parsing we do not provide. Do not let
          # an installed executable with the same name mask an unsupported header.
          [[ "$token" =~ $function_name && "$remaining" =~ $paren_header ]] || return 1
          header=${BASH_REMATCH[0]}
          name=$token
        fi
        if (( zsh_repeat_count_pending )); then
          # The count is data, but its substitutions were scanned above. Start
          # a new command boundary so compound bodies get their own headers
          # recognized too, rather than leaking short-for values as commands.
          case "$token" in ';'|'|'|'&'|'&&'|'||'|'('|')') return 1 ;; esac
          zsh_repeat_count_pending=0
          out+='; '
          command_start=1
        elif (( command_start )) && [[ "$shell" == zsh && "$token" == repeat ]]; then
          zsh_repeat_count_pending=1
          zsh_unscoped_loop_seen=1
          out+=' '
          command_start=0
        elif (( command_start )) && [[ "$token" == eval && -z "$name" && $'\n'"$functions"$'\n' != *$'\n'eval$'\n'* ]]; then
          if words=$(__lmline_extract_literal_eval_words "$remaining" "$shell" "$functions"); then
            while IFS= read -r word; do
              [[ -z "$word" ]] || substitutions+="; $word "
            done <<<"$words"
          else
            eval_status=$?
            (( eval_status == 2 )) || return 2
          fi
          out+=$token
          command_start=0
        elif (( command_start )) && [[ "$token" == trap && -z "$name" && $'\n'"$functions"$'\n' != *$'\n'trap$'\n'* ]]; then
          if words=$(__lmline_extract_literal_trap_words "$remaining" "$shell" "$functions"); then
            while IFS= read -r word; do
              [[ -z "$word" ]] || substitutions+="; $word "
            done <<<"$words"
          else
            trap_status=$?
            (( trap_status == 2 )) || return 2
          fi
          out+=$token
          command_start=0
        elif (( command_start )) && [[ ( "$token" == bash || "$token" == zsh ) && -z "$name" ]]; then
          if __lmline_extract_literal_shell_c_words "$token" "$remaining" "$functions"; then
            :
          else
            shellc_status=$?
            (( shellc_status == 2 )) || return 2
          fi
          out+=$token
          command_start=0
        elif (( command_start )) && [[ "$token" == coproc ]]; then
          # A coprocess body runs asynchronously, so it is checked like any
          # other command: consume only the header and leave the body as a new
          # command boundary. A NAME names the coprocess and precedes only a
          # compound body (`{ ...; }`, `( ... )`, `[[ ... ]]`, keyword bodies);
          # a simple body has no NAME, so the next word is the command itself
          # and stays visible. Never executes the body here.
          out+='; '
          command_start=1
          if [[ "$remaining" =~ $coproc_named_compound ]]; then
            [[ "$remaining" =~ ^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]* ]]
            i=$((i + ${#BASH_REMATCH[0]}))
            out+=' '
          fi
        elif (( command_start )) && [[ "$shell" == zsh && "$token" == for && "$remaining" =~ $zsh_for_header ]]; then
          header=${BASH_REMATCH[0]}
          zsh_for_words=${BASH_REMATCH[2]}
          # Parentheses in simple glob qualifiers such as *.txt(N) are static
          # list data. Leave substitutions, executable e-qualifiers and other
          # complex forms untouched so their commands remain conservatively scanned.
          if [[ "$zsh_for_words" == *'$('* || "$zsh_for_words" == *'`'* ||
                "$zsh_for_words" == *'<('* || "$zsh_for_words" == *'>('* ||
                "$zsh_for_words" == *'=('* || "$zsh_for_words" == *':'* ||
                "$zsh_for_words" == *';'* || "$zsh_for_words" == *'|'* ||
                "$zsh_for_words" == *'&'* || "$zsh_for_words" == *'+'* ||
                "$zsh_for_words" == *'#'* || "$zsh_for_words" == *'!'* ||
                "$zsh_for_words" == *'{'* || "$zsh_for_words" == *'}'* ||
                "$zsh_for_words" == *'\\'* || "$zsh_for_words" == *'"'* ||
                "$zsh_for_words" == *"'"* ]]; then
            out+=$token
            command_start=0
          else
            zsh_unscoped_loop_seen=1
            i=$((i + ${#header}))
            out+='; '
            command_start=1
          fi
        elif [[ -n "$name" ]]; then
          # Definitions in or after short-for/repeat loops need control-flow
          # reasoning to prove they run. Fail closed rather than let a possibly
          # skipped body satisfy a later call.
          (( zsh_unscoped_loop_seen == 0 )) || return 1
          (( list_operator[brace_depth] == 0 )) || return 1
          list_definition[brace_depth]=1
          brace_definition[brace_depth]=1
          brace_depth=$((brace_depth + 1))
          list_operator[brace_depth]=0
          list_definition[brace_depth]=0
          brace_definition[brace_depth]=0
          functions+=$'\n'"$name"$'\n'
          i=$((i + ${#header}))
          out+='; '
          command_start=1
        elif [[ "$token" == case && $command_start == 1 ]]; then
          depth=$((depth + 1))
          state[depth]=selector
          out+=' '
        elif (( depth > 0 )) && [[ "$token" == ';;' || "$token" == ';&' || "$token" == ';;&' || "$token" == ';|' ]]; then
          (( ${#scope_saved[@]} > 0 )) || return 1
          scope_idx=$((${#scope_saved[@]} - 1))
          [[ ${scope_kind[scope_idx]} == "case-branch" ]] || return 1
          functions=${scope_saved[scope_idx]}
          unset "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          state[depth]=pattern
          pattern_started=0
          pattern_depth=0
          out+='; '
        elif (( depth > 0 && command_start == 1 )) && [[ "$token" == "esac" ]]; then
          if (( ${#scope_saved[@]} > 0 )); then
            scope_idx=$((${#scope_saved[@]} - 1))
            if [[ ${scope_kind[scope_idx]} == "case-branch" ]]; then
              functions=${scope_saved[scope_idx]}
              unset "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
            fi
          fi
          depth=$((depth - 1))
          out+=' '
          command_start=0
          compound_end=1
        else
          case "$token" in
            '&&'|'||'|'|')
              (( list_definition[brace_depth] == 0 )) || return 1
              list_operator[brace_depth]=1
              ;;
            ';')
              list_operator[brace_depth]=0
              list_definition[brace_depth]=0
              ;;
            '{')
              if (( command_start )); then
                brace_depth=$((brace_depth + 1))
                list_operator[brace_depth]=0
                list_definition[brace_depth]=0
                brace_definition[brace_depth]=0
              fi
              ;;
            '}')
              if (( command_start || previous_compound_end )); then
                (( brace_depth > 0 )) || return 1
                name=${brace_definition[brace_depth]}
                brace_depth=$((brace_depth - 1))
                if (( name )); then
                  (( list_operator[brace_depth] == 0 )) || return 1
                  list_definition[brace_depth]=1
                  brace_definition[brace_depth]=1
                fi
                compound_end=1
              fi
              ;;
          esac
          # Conditional bodies are scoped: definitions inside an if branch,
          # loop body or subshell are visible only within that body, never
          # after the containing control flow. Direct unconditional
          # definitions and calls still pass through.
          if [[ "$token" == "if" && $command_start == 1 ]]; then
            if_pending=$((if_pending + 1))
          elif [[ "$token" == "then" && $command_start == 1 ]]; then
            if (( elif_pending > 0 )); then
              elif_pending=$((elif_pending - 1))
              (( ${#scope_saved[@]} > 0 )) || return 1
            elif (( if_pending > 0 )); then
              if_pending=$((if_pending - 1))
              scope_saved+=("$functions")
              scope_kind+=("if")
            else
              return 1
            fi
          elif [[ "$token" == "elif" && $command_start == 1 ]]; then
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "if" ]] || return 1
            functions=${scope_saved[scope_idx]}
            elif_pending=$((elif_pending + 1))
          elif [[ "$token" == "else" && $command_start == 1 ]]; then
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "if" ]] || return 1
            functions=${scope_saved[scope_idx]}
          elif [[ "$token" == "fi" && $command_start == 1 ]]; then
            compound_end=1
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "if" ]] || return 1
            functions=${scope_saved[scope_idx]}
            unset "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          elif [[ "$token" == "do" && $command_start == 1 ]]; then
            scope_saved+=("$functions")
            scope_kind+=("loop")
          elif [[ "$token" == "done" && $command_start == 1 ]]; then
            compound_end=1
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "loop" ]] || return 1
            functions=${scope_saved[scope_idx]}
            unset "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          elif [[ "$token" == '(' ]]; then
            scope_saved+=("$functions")
            scope_kind+=("subshell")
          elif [[ "$token" == ')' ]]; then
            compound_end=1
            (( ${#scope_saved[@]} > 0 )) || return 1
            scope_idx=$((${#scope_saved[@]} - 1))
            [[ ${scope_kind[scope_idx]} == "subshell" ]] || return 1
            functions=${scope_saved[scope_idx]}
            unset "scope_saved[$scope_idx]" "scope_kind[$scope_idx]"
          fi
          # A direct call to a previously declared candidate function needs no
          # external executable. Keep wrappers such as `command name` unchanged.
          if (( command_start )) && [[ $'\n'"$functions"$'\n' == *$'\n'"$token"$'\n'* ]]; then
            out+=':'
          else
            out+=$token
          fi
          case "$token" in
            ';'|'|'|'&'|'&&'|'||'|'('|')') command_start=1 ;;
            # Reserved words preserve an existing command boundary, but the
            # same words used as arguments must not manufacture a repeat body.
            '!'|if|then|else|do|while|until) : ;;
            time) [[ "$shell" == zsh ]] || command_start=0 ;;
            '{') : ;; # A brace argument does not start a command.
            *) command_start=0 ;;
          esac
        fi
        ;;
    esac
  done
  (( depth == 0 && brace_depth == 0 && zsh_repeat_count_pending == 0 )) || return 1
  (( ${#scope_saved[@]} == 0 )) || return 1
  (( if_pending == 0 && elif_pending == 0 )) || return 1
  if (( only_substitutions || only_literal_evals )); then
    printf '%s' "$substitutions"
  else
    printf '%s%s' "$out" "$substitutions"
  fi
}

__lmline_extract_command_words() {
  local cmd=$1 shell=${2:-bash} scan_substitutions=${3:-0} functions=${4:-} stripped segment token arithmetic array_assignment coproc_skip_next=0 eval_copy eval_status
  local function_definition='[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\([[:space:]]*\)'
  local coproc_compound_keywords='!|if|for|while|until|case|select|time|function|coproc'
  [[ "$shell" != zsh ]] || coproc_compound_keywords+='|repeat'
  local coproc_named_keywords='coproc[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]+('"$coproc_compound_keywords"')([[:space:];]|$)'
  local arithmetic_pattern='\(\([^()]*\)\)' array_pattern='[a-zA-Z_][a-zA-Z0-9_]*=\([^()]*\)'
  if [[ "$cmd" == *case* || "$cmd" == *function* || "$cmd" == *coproc* || "$cmd" =~ $function_definition || ( "$shell" == zsh && ( "$cmd" == *for* || "$cmd" == *repeat* ) ) ]] || (( scan_substitutions )); then
    cmd=$(__lmline_case_command_copy "$cmd" "$shell" 0 "$functions") || return 1
  elif [[ "$cmd" == *eval* || "$cmd" == *trap* || "$cmd" == *bash* || "$cmd" == *zsh* ]]; then
    # Reuse token boundaries without rewriting the original simple-command
    # path or checking substitutions in unsupported/dynamic eval/trap/shell-c arguments.
    # Unsupported outer syntax remains subject to the existing extractor.
    if eval_copy=$(__lmline_case_command_copy "$cmd" "$shell" 0 "$functions" 1); then
      cmd+=$eval_copy
    else
      eval_status=$?
      (( eval_status != 2 )) || return 1
    fi
  fi
  # Flat ((...)) arithmetic groups are shell expressions, not command words.
  # Strip them only from this availability-check copy; other policy checks
  # still see the original candidate, and nested forms remain conservative.
  while [[ "$cmd" =~ $arithmetic_pattern ]]; do
    arithmetic=${BASH_REMATCH[0]}
    cmd=${cmd/"$arithmetic"/ }
  done
  # Flat static array assignments contain data words, not commands. Keep
  # nested substitutions conservative by matching only simple parenthesis-free
  # values; other policy checks still use the unmodified candidate.
  while [[ "$cmd" =~ $array_pattern ]]; do
    array_assignment=${BASH_REMATCH[0]}
    cmd=${cmd/"$array_assignment"/ }
  done
  # A conservative lexical approximation: split at command separators and keep
  # the first simple command word after env assignments, negation, and builtins.
  # For zsh, parentheses attached to a glob word are its glob qualifier, not a
  # subshell boundary; the splitter preserves those pairs for this check only.
  stripped=$(__lmline_split_pipeline "$cmd" 0 "()" "$shell")

  while IFS= read -r segment; do
    coproc_skip_next=0
    for token in $segment; do
      if (( coproc_skip_next )); then
        coproc_skip_next=0
        continue
      fi
      [[ "$token" == *=* && "$token" != /* && "$token" != ./* && "$token" != ../* ]] && continue
      if [[ "$shell" == zsh && "$token" == repeat ]]; then
        # Supported repeat headers were removed by the syntax-aware copy.
        # Do not let an unsupported wrapper position mask its body by resolving
        # the reserved word itself as an available Zsh command.
        return 1
      fi
      if [[ "$token" == coproc ]]; then
        # A header the syntax-aware copy did not consume (for example after
        # `time` in Bash, which clears the command boundary). Skip it and any
        # same-segment NAME so the body stays visible; cross-segment NAME
        # forms were already consumed by the copy when at a boundary.
        if [[ "$segment" =~ coproc[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*(\{|\[|\() ]]; then
          coproc_skip_next=1
        elif [[ "$segment" =~ $coproc_named_keywords ]]; then
          coproc_skip_next=1
        fi
        continue
      fi
      if [[ "$token" == for ]]; then
        # A static word-list loop header names an iteration variable and
        # values, not commands; the semicolon splitter leaves its body in
        # following segments, where command checks continue as usual.
        break
      fi
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

# Target-shell command check for candidate validation only (never executes
# the word): zsh -f skips startup files, and the quoted $1 stays data.
__lmline_word_available_in_zsh() {
  local word=$1
  command -v zsh >/dev/null 2>&1 || return 1
  command zsh -f -c 'command -v "$1" >/dev/null 2>&1' _ "$word"
}

# Invoked-shell command check for literal `bash -c` scripts: ask a fresh Bash
# process so unexported caller-shell functions and aliases do not leak into
# the new shell's command namespace. Exported functions travel with the
# environment, and builtins and PATH lookups resolve in the child, so they
# stay available. The word stays data; the candidate script never runs.
__lmline_word_available_in_bash() {
  local word=$1
  command bash -c 'command -v "$1" >/dev/null 2>&1' _ "$word"
}

__lmline_validate_commands_available() {
  local cmd=$1 shell=${2:-bash}
  local word words
  words=$(__lmline_extract_command_words "$cmd" "$shell") || return 1
  while IFS= read -r word; do
    [[ -n "$word" ]] || continue
    [[ "$word" == */* ]] && continue
    __lmline_word_is_policy_skip "$word" && continue
    command -v "$word" >/dev/null 2>&1 && continue
    [[ "$shell" == zsh ]] && __lmline_word_available_in_zsh "$word" && continue
    return 1
  done <<<"$words"
  return 0
}
