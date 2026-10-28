# Names-only transport and clean Bash launch. Sourced by entry points/policy.
__LMLINE_BOUNDARY_DIR=${BASH_SOURCE[0]%/*}

# POSIX mode gives special builtins precedence over functions. Enter it using
# assignment syntax, then remove any shadow of `command` with the special
# builtin `unset`. No caller function, even `builtin`/`command`, is dispatched.
# All changes stay in a subshell; interactive options/functions are untouched.
__lmline_collect_shell_functions() (
  # Already-POSIX callers may have made POSIXLY_CORRECT readonly.
  [[ -o posix ]] || POSIXLY_CORRECT=1
  (
    unset -f command || exit 1
    command builtin compgen -A function
  ) || exit 1
  # The first view suppressed `command`; recover just that name from a
  # complementary view with `builtin` suppressed. Neither view calls either
  # function. This keeps the data complete even for these two helper names.
  (
    unset -f builtin || exit 1
    if builtin declare -F command >/dev/null; then builtin printf '%s\n' command; fi
  ) || exit 1
  :
)

# Inherited exported-function names for a protected (`bash -p`) entry.
# A protected startup never imports function bodies, so `declare -Fx` is
# empty there. This collector instead reads `/usr/bin/env -0` records
# opaquely into non-exported local scratch solely to emit names: it never
# sources/evaluates record values or candidate text, and never forwards
# bodies to validator input, argv, metadata, logs, provider payload, or
# exported scratch data. Export attributes on scratch are cleared before
# assignment (a plain `local` retains an inherited export attribute and would
# leak an assigned sentinel to children), the env producer's completion is
# checked explicitly, and descriptors/children are cleaned up.
__lmline_collect_inherited_exported_functions() (
  # Already-POSIX callers may have made POSIXLY_CORRECT readonly.
  [[ -o posix ]] || POSIXLY_CORRECT=1
  unset -f command || exit 1
  command builtin local entry name_part name fd producer
  command builtin export -n entry || exit 1
  command builtin export -n name_part || exit 1
  command builtin export -n name || exit 1
  command builtin export -n fd || exit 1
  command builtin export -n producer || exit 1
  command builtin exec {fd}< <(command /usr/bin/env -0) || exit 1
  producer=$!
  while IFS= command builtin read -r -d '' entry <&"$fd"; do
    case "$entry" in
      *=*) ;;
      *) continue ;;
    esac
    name_part=${entry%%=*}
    case "$name_part" in
      BASH_FUNC_*%%)
        name=${name_part#BASH_FUNC_}
        name=${name%\%\%}
        ;;
      *)
        # Legacy bash (4.2-4.3) exports functions as NAME=() {...}.
        # Opaque prefix check only; the body is never evaluated.
        case "$entry" in
          "$name_part="'()'* ) name=$name_part ;;
          *) continue ;;
        esac
        ;;
    esac
    [[ -n $name ]] || continue
    [[ $name =~ ^[A-Za-z0-9_/:.+@-]+$ ]] || continue
    command builtin printf '%s\n' "$name"
  done
  command builtin exec {fd}<&- || exit 1
  command builtin wait "$producer" || exit 1
  :
)

__lmline_collect_exported_functions() (
  # Already-POSIX callers may have made POSIXLY_CORRECT readonly.
  [[ -o posix ]] || POSIXLY_CORRECT=1
  if [[ -o privileged ]]; then
    __lmline_collect_inherited_exported_functions || exit 1
    :
  else
    (
      unset -f command || exit 1
      while IFS= command builtin read -r declaration; do
        name=${declaration##* }
        [[ $name =~ ^[A-Za-z0-9_/:.+@-]+$ ]] || continue
        command builtin printf '%s\n' "$name"
      done < <(command builtin declare -Fx)
    ) || exit 1
    (
      unset -f builtin || exit 1
      while IFS= builtin read -r declaration; do
        name=${declaration##* }
        if [[ $name == command ]]; then builtin printf '%s\n' "$name"; fi
      done < <(builtin declare -Fx)
    ) || exit 1
    :
  fi
)

__lmline_validation_run() (
  POSIXLY_CORRECT=1
  LMLINE_SHELL_FUNCTIONS=${__LMLINE_CALLER_FUNCTIONS-${LMLINE_SHELL_FUNCTIONS-$(__lmline_collect_shell_functions)}} || exit 1
  LMLINE_EXPORTED_FUNCTIONS=${__LMLINE_EXPORTED_FUNCTIONS-${LMLINE_EXPORTED_FUNCTIONS-$(__lmline_collect_exported_functions)}} || exit 1
  unset -f command || exit 1
  command builtin local kind="$1" key
  command builtin shift
  command builtin export LMLINE_SHELL_FUNCTIONS LMLINE_EXPORTED_FUNCTIONS
  # Policy settings may be shell-local in an interactive frontend. Forward
  # just this configuration, not arbitrary shell variables or function bodies.
  for key in LMLINE_DEFAULTS_DIR LMLINE_USER_RULES_DIR LMLINE_MAX_CANDIDATE_BYTES \
    LMLINE_SHELL_SYNTAX_WORDS_FILE LMLINE_SHELL_WORDS_FILE LMLINE_COMMAND_PREFIX_WORDS_FILE \
    LMLINE_RISK_PATTERNS_FILE LMLINE_RISK_BRACE_CAPPED_LEVEL LMLINE_RISK_HISTORY_EXPANSION_LEVEL \
    LMLINE_RISK_PIPED_SHELL_LEVEL LMLINE_RISK_RECURSIVE_REMOVE_LEVEL LMLINE_RISK_UNRESOLVED_VAR_LEVEL; do
    [[ ${!key+x} ]] && command builtin export "$key"
  done
  command builtin unset POSIXLY_CORRECT
  if [[ $kind == entry ]]; then
    command builtin exec "$BASH" -p "$@"
  else
    command builtin exec "$BASH" -p "$__LMLINE_BOUNDARY_DIR/validate" "$kind" "$@"
  fi
)
