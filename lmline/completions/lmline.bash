#!/usr/bin/env bash
# Standalone bash completion for the lmline CLI. Sourced by init.bash and
# usable on its own from ~/.bashrc without loading the shell widgets.
# Dynamic values come from "lmline complete ..." at completion time.

__lmline_cli_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local prev=${COMP_WORDS[COMP_CWORD-1]}
  local subcommands="doctor context command-exists command-info commands payload sandbox clip config endpoint model use current complete history risk help debug keys explain enable disable"
  local command=${COMP_WORDS[1]-}
  local sub=${COMP_WORDS[2]-}
  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "$subcommands" -- "$cur") )
  elif [[ $command == use && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete endpoints 2>/dev/null)" -- "$cur") )
  elif [[ $command == use && $COMP_CWORD == 3 ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete models "${COMP_WORDS[2]}" 2>/dev/null)" -- "$cur") )
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
  elif [[ $command == clip && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "--status --providers --use --provider" -- "$cur") )
  elif [[ $command == clip && $COMP_CWORD == 3 && ${prev} =~ ^(--use|--provider)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete clipboard-providers 2>/dev/null)" -- "$cur") )
  elif [[ $command == endpoint && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "add list set-secret remove" -- "$cur") )
  elif [[ $command == endpoint && $COMP_CWORD == 3 && ${sub} =~ ^(set-secret|remove)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete endpoints 2>/dev/null)" -- "$cur") )
  elif [[ $command == endpoint && $sub == add && $COMP_CWORD -ge 5 ]]; then
    if [[ $prev == --tool-mode ]]; then
      COMPREPLY=( $(compgen -W "auto openai text none" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "--auth-header --auth-scheme --temperature --max-tokens --tool-mode --models-url --models-jq --models-prefix --models-include --models-exclude --help" -- "$cur") )
    fi
  elif [[ $command == endpoint && $sub == remove && $COMP_CWORD -ge 4 ]]; then
    COMPREPLY=( $(compgen -W "--keep-secret --help" -- "$cur") )
  elif [[ $command == model && $COMP_CWORD == 2 ]]; then
    COMPREPLY=( $(compgen -W "add list refresh remove" -- "$cur") )
  elif [[ $command == model && $COMP_CWORD == 3 && ${sub} =~ ^(add|list|refresh|remove)$ ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete endpoints 2>/dev/null)" -- "$cur") )
  elif [[ $command == model && $COMP_CWORD == 4 && ${sub} == remove ]]; then
    COMPREPLY=( $(compgen -W "$(lmline complete models "${COMP_WORDS[3]}" 2>/dev/null)" -- "$cur") )
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
