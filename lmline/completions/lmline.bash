#!/usr/bin/env bash
# Standalone bash completion for the lmline CLI. Sourced by init.bash and
# usable on its own from ~/.bashrc without loading the shell widgets.
# Dynamic values come from "lmline complete ..." at completion time.

# Bash 4.2 exposes COMP_POINT as a byte offset; Bash 4.3+ reports
# characters. Convert the older offset to the character index used by Bash's
# multibyte substring expansion without changing the caller's locale.
__lmline_comp_point_char_offset() {
  local target=$1 line=${COMP_LINE-} point prefix saved_lc_all
  point=${COMP_POINT:-${#line}}
  if (( BASH_VERSINFO[0] < 4 ||
        (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    saved_lc_all=${LC_ALL-}
    local LC_ALL=C
    prefix=${line:0:point}
    LC_ALL=$saved_lc_all
    point=${#prefix}
  fi
  printf -v "$target" '%s' "$point"
}

# Validate ASCII shell syntax without making valid UTF-8 bytes locale-dependent.
__lmline_bash_prefix_is_shell_safe() {
  local LC_ALL=C ascii_prefix encoded_prefix
  ascii_prefix=${1//[$'\200'-$'\377']/}
  [[ -z $ascii_prefix ]] && return 0
  printf -v encoded_prefix '%q' "$ascii_prefix"
  [[ $encoded_prefix == "$ascii_prefix" ]]
}

# Insert reversible shell words for endpoint, model, and provider names. In
# quoted or escaped words, omit candidates that need encoding rather than
# corrupting existing quoting.
__lmline_complete_names_bash() {
  local kind=$1 endpoint=$2 cur=$3 id suffix encoded_suffix line point point_out raw_word
  local quoted_context=0
  local -a candidates=() completion_args=()
  case "$kind" in
    endpoints) completion_args=(complete endpoints --raw) ;;
    models) completion_args=(complete models --raw "$endpoint") ;;
    clipboard-providers) completion_args=(complete clipboard-providers) ;;
    *) COMPREPLY=(); return 0 ;;
  esac
  __lmline_comp_point_char_offset point_out
  point=$point_out
  line=${COMP_LINE:0:point}
  raw_word=${line##*[[:space:]]}
  if [[ $raw_word == *\"* || $raw_word == *\'* || $raw_word == *\\* ]]; then
    quoted_context=1
  fi
  if [[ -n "$cur" ]] && ! __lmline_bash_prefix_is_shell_safe "$cur"; then
    COMPREPLY=()
    return 0
  fi
  while IFS= read -r id; do
    [[ "$id" == "$cur"* ]] || continue
    suffix=${id#"$cur"}
    printf -v encoded_suffix '%q' "$suffix"
    if (( quoted_context )); then
      [[ "$encoded_suffix" == "$suffix" ]] || continue
      candidates+=("$id")
    else
      candidates+=("$cur$encoded_suffix")
    fi
  done < <(lmline "${completion_args[@]}" 2>/dev/null)
  COMPREPLY=("${candidates[@]}")
  (( quoted_context )) || compopt -o noquote 2>/dev/null || true
}

__lmline_cli_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local prev=${COMP_WORDS[COMP_CWORD-1]}
  local line point point_out raw_word
  __lmline_comp_point_char_offset point_out
  point=$point_out
  if (( point < ${#COMP_LINE} )); then
    line=${COMP_LINE:0:point}
    raw_word=${line##*[[:space:]]}
    if [[ $raw_word != *\"* &&
          $raw_word != *\'* &&
          $raw_word != *\\* &&
          $cur == "$raw_word"* ]]; then
      # COMP_WORDS retains the whole token when the cursor is before its suffix.
      # Use only a plain, unquoted prefix so every catalog follows Readline's cursor.
      cur=$raw_word
    fi
  fi
  local subcommands="doctor context command-exists command-info commands payload sandbox clip config endpoint model copilot chatgpt use current complete history risk help debug keys explain enable disable"
  local command=${COMP_WORDS[1]-}
  local sub=${COMP_WORDS[2]-}
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
  elif [[ $command == use && $COMP_CWORD == 2 ]]; then
    __lmline_complete_names_bash endpoints "" "$cur"
  elif [[ $command == use && $COMP_CWORD == 3 ]]; then
    __lmline_complete_names_bash models "${COMP_WORDS[2]}" "$cur"
  elif [[ $command == payload && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "generate rewrite explain fix clip" -- "$cur") )
  elif [[ $command == help && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete commands 2>/dev/null)" -- "$cur") )
  elif [[ $command == help && $COMP_CWORD == 3 ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete subcommands "${COMP_WORDS[2]}" 2>/dev/null)" -- "$cur") )
  elif [[ $command == sandbox && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "setup run check" -- "$cur") )
  elif [[ $command == sandbox && $sub == setup && $prev == --workspace ]]; then
    COMPREPLY=( $(compgen -W "readonly writable none" -- "$cur") )
  elif [[ $command == sandbox && $sub == setup && $COMP_CWORD -ge 3 ]]; then
    COMPREPLY=( $(compgen -W "--name --image --workspace --root --workdir --timeout --help" -- "$cur") )
  elif [[ $command == sandbox && $sub == run && $COMP_CWORD -ge 3 ]]; then
    COMPREPLY=( $(compgen -W "--name --image --timeout --max-output --help --" -- "$cur") )
  elif [[ $command == copilot && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "setup update login status logout restart remove" -- "$cur") )
  elif [[ $command == chatgpt && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "login status refresh reauth logout" -- "$cur") )
  elif [[ $command == clip && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "--status --providers --use --provider" -- "$cur") )
  elif [[ $command == clip && $COMP_CWORD == 3 && ${prev} =~ ^(--use|--provider)$ ]]; then
    __lmline_complete_names_bash clipboard-providers "" "$cur"
  elif [[ $command == endpoint && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "add list set-secret remove" -- "$cur") )
  elif [[ $command == endpoint && $COMP_CWORD == 3 && ${sub} =~ ^(set-secret|remove)$ ]]; then
    __lmline_complete_names_bash endpoints "" "$cur"
  elif [[ $command == endpoint && $sub == add && $COMP_CWORD -ge 5 ]]; then
    if [[ $prev == --tool-mode ]]; then
      COMPREPLY=( $(compgen -W "auto openai text none" -- "$cur") )
    elif [[ $prev == --auth-mode ]]; then
      COMPREPLY=( $(compgen -W "api-key chatgpt" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "--auth-header --auth-scheme --auth-mode --temperature --max-tokens --tool-mode --models-url --models-jq --models-prefix --models-include --models-exclude --help" -- "$cur") )
    fi
  elif [[ $command == endpoint && $sub == remove && $COMP_CWORD -ge 4 ]]; then
    COMPREPLY=( $(compgen -W "--keep-secret --help" -- "$cur") )
  elif [[ $command == model && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "add list refresh remove" -- "$cur") )
  elif [[ $command == model && $COMP_CWORD == 3 && ${sub} =~ ^(add|list|refresh|remove)$ ]]; then
    __lmline_complete_names_bash endpoints "" "$cur"
  elif [[ $command == model && $COMP_CWORD == 4 && ${sub} == remove ]]; then
    __lmline_complete_names_bash models "${COMP_WORDS[3]}" "$cur"
  elif [[ $command == model && $sub == add && $COMP_CWORD -ge 5 ]]; then
    if [[ $prev == --tool-mode ]]; then
      COMPREPLY=( $(compgen -W "auto openai text none" -- "$cur") )
    elif [[ $prev == --api-format ]]; then
      COMPREPLY=( $(compgen -W "chat responses messages" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "--temperature --max-tokens --tool-mode --api-format --help" -- "$cur") )
    fi
  elif [[ $command == config && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "get defaults effective describe set unset project-get project-set project-unset" -- "$cur") )
  elif [[ $command == config && $COMP_CWORD == 3 && ${sub} =~ ^(describe|set|unset|project-set|project-unset)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete settings 2>/dev/null)" -- "$cur") )
  elif [[ $command == config && $COMP_CWORD == 4 && ${sub} =~ ^(set|project-set)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete setting-values "${COMP_WORDS[3]}" 2>/dev/null)" -- "$cur") )
  elif [[ $command == complete && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "commands subcommands settings setting-values endpoints models clipboard-providers" -- "$cur") )
  elif [[ $command == complete && $COMP_CWORD == 3 && ${sub} == subcommands ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete commands 2>/dev/null)" -- "$cur") )
  elif [[ $command == complete && $COMP_CWORD == 3 && ${sub} == setting-values ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete settings 2>/dev/null)" -- "$cur") )
  elif [[ $command == history && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "show tendencies" -- "$cur") )
  elif [[ $command == debug && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "bindings on off trace" -- "$cur") )
  elif [[ $command == debug && $COMP_CWORD == 3 && $sub == trace ]]; then
    COMPREPLY=( $(compgen -W "on off" -- "$cur") )
  elif [[ $command == doctor && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "--check-api --help" -- "$cur") )
  fi
}

complete -F __lmline_cli_complete lmline 2>/dev/null || true
