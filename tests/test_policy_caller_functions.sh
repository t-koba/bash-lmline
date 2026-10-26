#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the validator runs in the engine child process, where non-exported
# parent-shell functions are absent; the frontend passes only their names.
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

caller_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-caller-functions.XXXXXX")
trap 'rm -rf "$caller_tmp"' EXIT

# The probe names below are never defined as real functions in this shell, so
# acceptance must come from the transported name list, never from `command -v`.
check_caller() {
  local target=$1 candidate=$2 expected=$3 caller_list=$4 actual
  if [[ "$target" == zsh ]]; then
    command -v zsh >/dev/null 2>&1 || return 0
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  unset __LMLINE_CALLER_FUNCTIONS
  actual=$(LMLINE_SHELL_FUNCTIONS="$caller_list" __LMLINE_VALIDATION_ISOLATED=1 __lmline_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target caller functions: $actual, expected $expected: $candidate (list: $caller_list)"
}

# Exercise the named results using the same local names as the parser call
# site: nested scans must not accidentally write a shadowing helper local.
check_trap_state() {
  local target=$1 remaining=$2 expected=$3 words=stale trap_functions=stale normalized="" line
  local __lmline_trap_caller_functions=$'\n'audit_caller_fn$'\n'
  __lmline_extract_literal_trap_words "$remaining" "$target" "$__lmline_trap_caller_functions" words trap_functions || fail "$target literal trap helper failed: $remaining"
  [[ "$words" != stale ]] || fail "trap helper did not return command words"
  while IFS= read -r line; do
    [[ -z "$line" ]] || normalized+=$'\n'"$line"$'\n'
  done <<<"$trap_functions"
  [[ "$normalized" == "$expected" ]] || fail "trap helper lost its named state result: $remaining"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  check_trap_state "$target" " 'unset -f audit_caller_fn' EXIT # DEBUG" $'\n'audit_caller_fn$'\n'
  check_trap_state "$target" " 'unset -f audit_caller_fn' DEBUG" ''
  check_trap_state "$target" " '' DEBUG" $'\n'audit_caller_fn$'\n'
  check_trap_state "$target" " '-' EXIT" $'\n'audit_caller_fn$'\n'
  # Active caller-shell function names are accepted as top-level commands,
  # including valid non-identifier punctuation and slash names.
  check_caller "$target" 'lmline_caller_probe_fn' ok 'lmline_caller_probe_fn'
  check_caller "$target" 'lmline-caller-probe' ok 'lmline-caller-probe'
  check_caller "$target" 'lmline_caller_dir/lmline-caller-probe' ok 'lmline_caller_dir/lmline-caller-probe'
  check_caller "$target" 'printf "$(lmline_caller_dir/lmline-caller-probe)"' ok 'lmline_caller_dir/lmline-caller-probe'
  check_caller "$target" 'lmline_caller_probe_fn --flag' ok 'lmline_caller_probe_fn'
  check_caller "$target" 'printf ok; lmline_caller_probe_fn' ok 'lmline_other_fn
lmline_caller_probe_fn'
  # Function-bypassing wrappers cannot use a non-exported transported name.
  check_caller "$target" "command audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "env audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "command audit_caller_dir/audit-caller" command-not-found audit_caller_dir/audit-caller
  check_caller "$target" "env audit_caller_dir/audit-caller" command-not-found audit_caller_dir/audit-caller
  # Literal trap actions run later: registration-time transport is not proof
  # of availability then. Action removals must not authorize subsequent calls.
  check_caller "$target" 'audit_caller_fn' ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' 0; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' EXIT 0; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' EXIT DEBUG; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' TERM; audit_caller_fn" command-not-found audit_caller_fn
  # Later literal scans cannot restore the transported name removed by an
  # early action, including when the subsequent trap is empty/reset.
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG; trap 'printf ok' EXIT; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG; trap '' DEBUG; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG; trap '-' DEBUG; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG; eval 'audit_caller_fn'" command-not-found audit_caller_fn
  check_caller "$target" "eval 'unset -f audit_caller_fn; audit_caller_fn() { printf replacement; }'; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "eval 'unset -f audit_caller_fn; audit_caller_fn() { printf replacement; }' & audit_caller_fn" ok audit_caller_fn
  # Replacing a removed name inside an early action cannot restore its old
  # binding outside the action: new body summaries are not transferred.
  check_caller "$target" "trap 'unset -f audit_caller_fn; audit_caller_fn() { printf replacement; }' DEBUG; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn; audit_caller_fn() { printf replacement; }' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap '( unset -f audit_caller_fn; audit_caller_fn() { printf replacement; } )' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'audit_remove_helper() { unset -f audit_caller_fn; }; audit_remove_helper; audit_caller_fn() { printf replacement; }' DEBUG; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'audit_caller_fn' EXIT; audit_remove_helper() { unset -f audit_caller_fn; }; audit_remove_helper" command-not-found audit_caller_fn
  check_caller "$target" "trap 'audit_caller_fn' EXIT; unset -f audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "trap 'printf audit_caller_fn' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'printf audit_caller_fn_extra' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_other_fn' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -v audit_caller_fn' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'printf unset -f audit_caller_fn' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'printf ok # unset -f audit_caller_fn' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap '( unset -f audit_caller_fn )' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn &' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap '' DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap '-' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap - DEBUG; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG; printf ok" ok audit_caller_fn
  check_caller "$target" "trap 'printf ok' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'audit_caller_fn_extra() { printf ok; }; audit_caller_fn_extra' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "audit_candidate_fn() { printf ok; }; trap 'audit_candidate_fn' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'audit_caller_fn() { printf ok; }; audit_caller_fn' EXIT" ok audit_caller_fn
  # Explicit candidate definitions win transport-name collisions in traps.
  # Duplicate input cannot forge this provenance; removal cannot revive it.
  check_caller "$target" "audit_caller_fn() { printf ok; }; trap 'audit_caller_fn' EXIT" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; trap 'audit_caller_fn' DEBUG" ok audit_caller_fn
  check_caller "$target" "trap 'audit_caller_fn' EXIT" command-not-found $'audit_caller_fn\naudit_caller_fn'
  check_caller "$target" "audit_caller_fn() { printf ok; }; unset -f audit_caller_fn; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "unset -f audit_caller_fn; audit_caller_fn() { printf ok; }; trap 'audit_caller_fn' EXIT" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; trap 'audit_caller_fn_extra' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "trap 'audit_caller_fn' EXIT" command-not-found ''
  # Recursive scans inherit provenance; isolated/uncertain scopes restore it.
  check_caller "$target" "audit_caller_fn() { printf ok; }; ( trap 'audit_caller_fn' EXIT )" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; audit_helper() { trap 'audit_caller_fn' EXIT; }" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; trap 'printf \"\$(audit_caller_fn)\"' EXIT" ok audit_caller_fn
  check_caller "$target" "( audit_caller_fn() { printf ok; }; trap 'audit_caller_fn' EXIT ); trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "{ audit_caller_fn() { printf ok; }; } & trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "audit_helper() { audit_caller_fn() { printf ok; }; }; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "audit_installer() { audit_caller_fn() { printf ok; }; }; audit_installer; trap 'audit_caller_fn' EXIT" ok audit_caller_fn
  check_caller "$target" "if true; then audit_caller_fn() { printf ok; }; fi; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "case x in x) audit_caller_fn() { printf ok; };; esac; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  # A recursive scan's surviving-input list is reset, so provenance must
  # survive even after the original transported binding was removed/replaced.
  check_caller "$target" "unset -f audit_caller_fn; audit_caller_fn() { printf ok; }; printf \"\$(trap 'audit_caller_fn' EXIT)\"" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; printf \"\$(unset -f audit_caller_fn; trap 'audit_caller_fn' EXIT)\"" command-not-found audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; ( unset -f audit_caller_fn ); trap 'audit_caller_fn' EXIT" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; bash -c 'audit_caller_fn'" command-not-found audit_caller_fn
  if command -v zsh >/dev/null 2>&1; then
    check_caller "$target" "audit_caller_fn() { printf ok; }; zsh -f -c 'audit_caller_fn'" command-not-found audit_caller_fn
  fi
  # Action-local definitions never install outer provenance. Early removals
  # invalidate a collision too, while EXIT removal preserves earlier state.
  check_caller "$target" "trap 'audit_caller_fn() { printf ok; }; audit_caller_fn' DEBUG; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; trap 'unset -f audit_caller_fn' DEBUG; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; trap 'unset -f audit_caller_fn' EXIT; trap 'audit_caller_fn' EXIT" ok audit_caller_fn
  check_caller "$target" "audit_caller_fn() { printf ok; }; eval 'unset -f audit_caller_fn'; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  if [[ "$target" == zsh ]]; then
    check_caller "$target" "audit_caller_fn() { printf ok; }; unfunction audit_caller_fn; trap 'audit_caller_fn' EXIT" command-not-found audit_caller_fn
  fi
  # Command positions inside compound actions/substitutions count too;
  # mentioning the same name in an argument or a comment does not.
  check_caller "$target" "trap 'if true; then audit_caller_fn; fi' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "trap 'printf \"\$(audit_caller_fn)\"' EXIT" command-not-found audit_caller_fn
  check_caller "$target" "trap 'printf ok # audit_caller_fn' EXIT; audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "( trap 'unset -f audit_caller_fn' DEBUG ); audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "trap 'unset -f audit_caller_fn' DEBUG & audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "{ trap 'unset -f audit_caller_fn' DEBUG; } & audit_caller_fn" ok audit_caller_fn
  check_caller "$target" "{ trap 'unset -f audit_caller_fn' DEBUG; }; audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "( trap 'unset -f audit_caller_fn' DEBUG; audit_caller_fn ); audit_caller_fn" command-not-found audit_caller_fn
  check_caller "$target" "audit_remove_helper() { trap 'unset -f audit_caller_fn' DEBUG; }; audit_remove_helper; audit_caller_fn" command-not-found audit_caller_fn
  if [[ "$target" == zsh ]]; then
    check_caller "$target" "trap 'unfunction audit_caller_fn' DEBUG; audit_caller_fn" command-not-found audit_caller_fn
    check_caller "$target" "trap 'unfunction audit_caller_fn' EXIT; audit_caller_fn" ok audit_caller_fn
    check_caller "$target" "trap 'unfunction audit_other_fn' DEBUG; audit_caller_fn" ok audit_caller_fn
  fi
  # An absent name is still rejected.
  check_caller "$target" 'lmline_caller_probe_fn' command-not-found 'lmline_other_fn'
  check_caller "$target" 'lmline_caller_probe_fn' command-not-found ''
  # Exact line membership: a longer stored name must not match by prefix, and
  # a space-joined transport is one invalid line, not two names.
  check_caller "$target" 'lmline_caller_probe_fn' command-not-found 'lmline_caller_probe_fn_extra'
  check_caller "$target" 'lmline_caller_probe_fn' ok 'lmline_caller_probe_fn_extra
lmline_caller_probe_fn'
  check_caller "$target" 'lmline_caller_probe_fn' command-not-found 'lmline_caller_probe_fn lmline_other_fn'
  # Unsafe stored lines never authorize a different command.
  check_caller "$target" 'definitely-not-a-command-for-lmline' command-not-found 'definitely-not-a-command-for-lmline;other'
  # A nested literal shell script does not inherit the parent list, even when
  # it names the same plain or slash-containing function.
  check_caller "$target" "bash -c 'lmline-caller-probe'" command-not-found 'lmline-caller-probe'
  check_caller "$target" "bash -c 'lmline_caller_dir/lmline-caller-probe'" command-not-found 'lmline_caller_dir/lmline-caller-probe'
  check_caller "$target" "bash -c 'printf \"\$(lmline_caller_dir/lmline-caller-probe)\"'" command-not-found 'lmline_caller_dir/lmline-caller-probe'
  if command -v zsh >/dev/null 2>&1; then
    check_caller "$target" "zsh -f -c 'lmline_caller_probe_fn'" command-not-found 'lmline_caller_probe_fn'
    check_caller "$target" "zsh -f -c 'lmline_caller_dir/lmline-caller-probe'" command-not-found 'lmline_caller_dir/lmline-caller-probe'
    check_caller "$target" "zsh -f -c 'printf \"\$(lmline_caller_dir/lmline-caller-probe)\"'" command-not-found 'lmline_caller_dir/lmline-caller-probe'
  fi
  # Removal is stateful: a call before removal remains valid, but a later
  # call must use ordinary lookup. Neither removals nor recursive scans mutate
  # the original transport used by the next, independent validation.
  removers=('unset -f')
  [[ "$target" != zsh ]] || removers+=(unfunction)
  for caller_name in lmline_caller_probe_fn lmline-caller-probe lmline_caller_dir/lmline-caller-probe; do
    for remover in "${removers[@]}"; do
      check_caller "$target" "$caller_name; $remover $caller_name" ok "$caller_name"
      check_caller "$target" "$caller_name; $remover $caller_name; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "$remover lmline_other_fn; $caller_name" ok "$caller_name"
      check_caller "$target" "unset -v lmline_caller_variable; $caller_name" ok "$caller_name"
      # Pure remover summaries transfer only when the adjacent helper is
      # called; an uncalled body must not change parent state.
      check_caller "$target" "lmline_remove_helper() { $remover $caller_name; }; lmline_remove_helper; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "lmline_remove_helper() { $remover $caller_name; }; $caller_name" ok "$caller_name"
      check_caller "$target" "lmline_remove_helper() { $remover $caller_name; }; 'lmline_remove_helper'; $caller_name" command-not-found "$caller_name"
      # Child changes do not leak back; parent changes do reach children.
      check_caller "$target" "( $remover $caller_name ); $caller_name" ok "$caller_name"
      check_caller "$target" "( $remover $caller_name; $caller_name )" command-not-found "$caller_name"
      check_caller "$target" "$remover $caller_name; ( $caller_name )" command-not-found "$caller_name"
      check_caller "$target" "{ $remover $caller_name; }; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "{ $remover $caller_name; } & $caller_name" ok "$caller_name"
      # Recursive scans inherit the active local set, not the untouched
      # transport. Substitutions are isolated; literal eval changes this shell.
      check_caller "$target" "printf \"\$($caller_name)\"" ok "$caller_name"
      check_caller "$target" "$remover $caller_name; printf \"\$($caller_name)\"" command-not-found "$caller_name"
      check_caller "$target" "printf \"\$($remover $caller_name)\"; $caller_name" ok "$caller_name"
      check_caller "$target" "eval '$caller_name'" ok "$caller_name"
      check_caller "$target" "eval '$remover $caller_name'; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "eval '$caller_name; $remover $caller_name'" ok "$caller_name"
      check_caller "$target" "eval '$caller_name; $remover $caller_name'; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "eval '$remover lmline_other_fn'; $caller_name" ok "$caller_name"
      check_caller "$target" "eval 'unset -v lmline_caller_probe_fn'; $caller_name" ok "$caller_name"
      check_caller "$target" "eval 'lmline_remove_helper() { $remover $caller_name; }; lmline_remove_helper'; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "printf \"\$(eval '$remover $caller_name')\"; $caller_name" ok "$caller_name"
      check_caller "$target" "( eval '$remover $caller_name' ); $caller_name" ok "$caller_name"
      check_caller "$target" "eval '$remover $caller_name' & $caller_name" ok "$caller_name"
      check_caller "$target" "if true; then eval '$remover $caller_name'; fi; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "lmline_remove_helper() { eval '$remover $caller_name'; }; lmline_remove_helper; $caller_name" command-not-found "$caller_name"
      # A subsequent validation starts from the untouched transport snapshot.
      check_caller "$target" "$caller_name" ok "$caller_name"
      check_caller "$target" "$remover $caller_name; eval '$caller_name'" command-not-found "$caller_name"
      check_caller "$target" "trap '$caller_name' EXIT" command-not-found "$caller_name"
      check_caller "$target" "$remover $caller_name; trap '$caller_name' EXIT" command-not-found "$caller_name"
      # Supported whole-word quotes must match the same active function, and
      # must not restore it after removal (including slash names).
      check_caller "$target" "'$caller_name'; \"$caller_name\"" ok "$caller_name"
      check_caller "$target" "$remover $caller_name; '$caller_name'" command-not-found "$caller_name"
      check_caller "$target" "$remover $caller_name; \"$caller_name\"" command-not-found "$caller_name"
      # Unknown options, quoted removal operands and variable-name punctuation
      # stay outside the literal removal grammar.
      check_caller "$target" "$remover -x; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "$remover '$caller_name'; $caller_name" command-not-found "$caller_name"
      check_caller "$target" "$caller_name" ok "$caller_name"
    done
    # A fresh shell starts without any transported names, even when they
    # appear only in a nested substitution of its literal script.
    for fresh_shell in 'bash -c' 'zsh -f -c'; do
      [[ "$fresh_shell" != zsh* ]] || command -v zsh >/dev/null 2>&1 || continue
      check_caller "$target" "$fresh_shell '$caller_name'" command-not-found "$caller_name"
      check_caller "$target" "$fresh_shell 'printf \"\$($caller_name)\"'" command-not-found "$caller_name"
    done
  done
  check_caller "$target" "lmline_''caller_probe_fn" ok lmline_caller_probe_fn
  check_caller "$target" "unset -f lmline_caller_probe_fn; lmline_''caller_probe_fn" command-not-found lmline_caller_probe_fn
  check_caller "$target" 'unset -v lmline-caller-probe; lmline-caller-probe' command-not-found lmline-caller-probe
  check_caller "$target" 'unset -v lmline_caller_dir/lmline-caller-probe; lmline_caller_dir/lmline-caller-probe' command-not-found lmline_caller_dir/lmline-caller-probe
  # Removing a transported binding is not a blanket denial: static lookup
  # can still find a real builtin, PATH executable or executable explicit path.
  check_caller "$target" 'unset -f printf; printf ok' ok printf
  printf '#!/bin/sh\nexit 99\n' >"$caller_tmp/lmline-caller-path-probe"
  chmod +x "$caller_tmp/lmline-caller-path-probe"
  PATH="$caller_tmp:$PATH" check_caller "$target" 'unset -f lmline-caller-path-probe; lmline-caller-path-probe' ok lmline-caller-path-probe
  PATH="$caller_tmp:$PATH" check_caller "$target" 'command lmline-caller-path-probe' ok lmline-caller-path-probe
  PATH="$caller_tmp:$PATH" check_caller "$target" 'env lmline-caller-path-probe' ok lmline-caller-path-probe
  check_caller "$target" "unset -f $caller_tmp/lmline-caller-path-probe; $caller_tmp/lmline-caller-path-probe" ok "$caller_tmp/lmline-caller-path-probe"
  ok "$target caller-shell function names"
done

# The candidate is never evaluated and a same-named stub is never called:
# defining the stub only proves the name resolves; the marker proves silence.
# shellcheck disable=SC2329 # looked up by name through the validator only
lmline_caller_exec_probe() { touch "$caller_tmp/executed"; }
unset __LMLINE_CALLER_FUNCTIONS
actual=$(LMLINE_SHELL_FUNCTIONS='lmline_caller_exec_probe' __lmline_candidate_rejection_reason 'lmline_caller_exec_probe' rewrite bash)
[[ "$actual" == ok ]] || fail "exec probe was not accepted: $actual"
[[ ! -e "$caller_tmp/executed" ]] || fail "candidate validation executed the function body"
for target in bash zsh; do
  check_caller "$target" "eval 'lmline_caller_exec_probe; touch $caller_tmp/executed; unset -f lmline_caller_exec_probe'" ok lmline_caller_exec_probe
  [[ ! -e "$caller_tmp/executed" ]] || fail "literal eval analysis executed candidate or function body"
  check_caller "$target" "trap 'lmline_caller_exec_probe; touch $caller_tmp/executed' EXIT" command-not-found lmline_caller_exec_probe
  check_caller "$target" "trap 'touch $caller_tmp/executed; unset -f lmline_caller_exec_probe' EXIT; lmline_caller_exec_probe" ok lmline_caller_exec_probe
  check_caller "$target" "trap 'touch $caller_tmp/executed; unset -f lmline_caller_probe_fn' DEBUG; lmline_caller_probe_fn" command-not-found lmline_caller_probe_fn
  check_caller "$target" "audit_caller_fn() { touch $caller_tmp/executed; printf \"\$(touch $caller_tmp/substitution)\"; }; trap 'audit_caller_fn' EXIT; touch $caller_tmp/candidate" ok audit_caller_fn
  [[ ! -e "$caller_tmp/substitution" && ! -e "$caller_tmp/candidate" ]] || fail "trap provenance analysis executed candidate text"
  [[ ! -e "$caller_tmp/executed" ]] || fail "literal trap analysis executed candidate or function body"
done
unset -f lmline_caller_exec_probe
ok "caller-shell candidate never evaluated"

# The collector emits names only, never bodies.
# shellcheck disable=SC2329 # listed by the collector; never invoked by it
lmline_collect_probe_fn() { printf '%s' "body-marker-$caller_tmp"; }
collected=$(__lmline_collect_shell_functions)
[[ $'\n'"$collected"$'\n' == *$'\n'"lmline_collect_probe_fn"$'\n'* ]] || fail "collector missed the probe name"
[[ "$collected" != *"body-marker"* ]] || fail "collector leaked a function body"
unset -f lmline_collect_probe_fn
ok "collector emits names only"

# The snapshot captures the transport and unsets it, and the snapshot alone
# still validates.
LMLINE_SHELL_FUNCTIONS='lmline_snapshot_probe_fn'
LMLINE_EXPORTED_FUNCTIONS='lmline_export_snapshot_probe_fn'
__lmline_snapshot_caller_functions
[[ -z ${LMLINE_SHELL_FUNCTIONS-} && -z ${LMLINE_EXPORTED_FUNCTIONS-} ]] || fail "snapshot left a transport set"
[[ ${__LMLINE_EXPORTED_FUNCTIONS-} == lmline_export_snapshot_probe_fn ]] || fail "snapshot lost the exported list"
[[ ${__LMLINE_CALLER_FUNCTIONS-} == 'lmline_snapshot_probe_fn' ]] || fail "snapshot lost the list"
actual=$(__lmline_candidate_rejection_reason 'lmline_snapshot_probe_fn; unset -f lmline_snapshot_probe_fn; lmline_snapshot_probe_fn' rewrite bash)
[[ "$actual" == command-not-found ]] || fail "snapshot removal was ignored: $actual"
[[ ${__LMLINE_CALLER_FUNCTIONS-} == 'lmline_snapshot_probe_fn' ]] || fail "validation mutated the snapshot"
actual=$(__lmline_candidate_rejection_reason 'lmline_snapshot_probe_fn' rewrite bash)
[[ "$actual" == ok ]] || fail "snapshot list was not accepted after separate removal validation: $actual"
unset __LMLINE_CALLER_FUNCTIONS
actual=$(__lmline_candidate_rejection_reason 'lmline_snapshot_probe_fn' rewrite bash)
[[ "$actual" == command-not-found ]] || fail "unset snapshot still validates: $actual"
unset __LMLINE_EXPORTED_FUNCTIONS
ok "snapshot captures and unsets both transports"

# Imported Bash exports must follow scan-local lifetime, not be resurrected
# by the validator's own lookup or a fresh Bash probe. Each check uses a real
# child importing the exports; candidate text is only parsed/inspected there.
check_exported() {
  local candidate=$1 expected=$2 actual
  bash -n -c "$candidate" || fail "invalid exported-function fixture: $candidate"
  actual=$(bash -c 'source "$1/lmline/policy.bash"; __lmline_candidate_rejection_reason "$2" rewrite bash' _ "$repo_dir" "$candidate")
  [[ "$actual" == "$expected" ]] || fail "exported functions: $actual, expected $expected: $candidate"
}
# shellcheck disable=SC2329 # imported and resolved by name only; never invoked
lmline_export_lifetime_probe() { touch "$caller_tmp/export-function-executed"; }
# shellcheck disable=SC2329
lmline_export_unrelated_probe() { touch "$caller_tmp/export-unrelated-executed"; }
export -f lmline_export_lifetime_probe lmline_export_unrelated_probe
export caller_tmp
# Other attributes may appear beside -fx; the collector still emits names only.
collected=$(declare -ft lmline_export_lifetime_probe; __lmline_collect_exported_functions)
[[ $'\n'"$collected"$'\n' == *$'\n'lmline_export_lifetime_probe$'\n'* ]] || fail "collector missed a traced export"
[[ "$collected" != *touch* ]] || fail "export collector leaked a function body"
check_exported 'lmline_export_lifetime_probe' ok
# Supported command prefixes retain the position-local function namespace,
# including the inherited-export view used by a literal child Bash. They do
# not widen the standalone remover/installer inference edge.
for prefix in time 'time -p' 'X=1' 'X+=1' 'X=1 Y=2' 'time X=1'; do
  check_exported "$prefix lmline_export_lifetime_probe" ok
  check_exported "bash -c '$prefix lmline_export_lifetime_probe'" ok
  check_exported "$prefix bash -c 'lmline_export_lifetime_probe'" ok
  check_exported "unset -f lmline_export_lifetime_probe; $prefix lmline_export_lifetime_probe" command-not-found
  check_exported "$prefix bash -c 'unset -f lmline_export_lifetime_probe; lmline_export_lifetime_probe'" command-not-found
  check_exported "unset -f lmline_export_lifetime_probe; $prefix bash -c 'lmline_export_lifetime_probe'" command-not-found
  check_exported "$prefix lmline_export_lifetime_probe; unset -f lmline_export_lifetime_probe" ok
  check_exported "$prefix bash -c 'lmline_export_lifetime_probe; unset -f lmline_export_lifetime_probe'" ok
  check_exported "$prefix bash -c 'lmline_export_lifetime_probe'; unset -f lmline_export_lifetime_probe" ok
  check_exported "$prefix unset -f lmline_export_lifetime_probe; lmline_export_lifetime_probe" command-not-found
  for query in -v -V; do
    check_exported "$prefix command $query unset; lmline_export_lifetime_probe" ok
    check_exported "bash -c '$prefix command $query unset; lmline_export_lifetime_probe'" ok
  done
done
check_exported 'time -x lmline_export_lifetime_probe' command-not-found
check_exported "lmline_export_lifetime_probe; touch $caller_tmp/export-candidate-executed" ok
check_exported "bash -c 'lmline_export_lifetime_probe'" ok
check_exported 'lmline_export_absent_probe' command-not-found
check_exported "bash -c 'lmline_export_absent_probe'" command-not-found
check_exported 'unset -f lmline_export_lifetime_probe; lmline_export_lifetime_probe' command-not-found
check_exported "unset -f lmline_export_lifetime_probe; bash -c 'lmline_export_lifetime_probe'" command-not-found
check_exported "bash -c 'unset -f lmline_export_lifetime_probe; lmline_export_lifetime_probe'" command-not-found
check_exported "unset -f lmline_export_lifetime_probe; lmline_export_lifetime_probe() { :; }; bash -c 'lmline_export_lifetime_probe'" command-not-found
check_exported "lmline_export_lifetime_probe() { :; }; bash -c 'lmline_export_lifetime_probe'" ok
check_exported 'lmline_export_lifetime_probe; unset -f lmline_export_lifetime_probe' ok
check_exported "bash -c 'lmline_export_lifetime_probe'; unset -f lmline_export_lifetime_probe" ok
check_exported "bash -c 'lmline_export_lifetime_probe; unset -f lmline_export_lifetime_probe'" ok
check_exported "unset -f lmline_export_lifetime_probe; lmline_export_unrelated_probe; bash -c 'lmline_export_unrelated_probe'" ok
# Removals in isolated scopes do not remove the parent's exported binding.
check_exported "(unset -f lmline_export_lifetime_probe); bash -c 'lmline_export_lifetime_probe'" ok
check_exported "bash -c 'unset -f lmline_export_lifetime_probe'; lmline_export_lifetime_probe" ok
for wrapper in command 'command --' env; do
  check_exported "$wrapper lmline_export_lifetime_probe" command-not-found
  check_exported "bash -c '$wrapper lmline_export_lifetime_probe'" command-not-found
  check_exported "unset -f lmline_export_lifetime_probe; $wrapper lmline_export_lifetime_probe" command-not-found
done
for query in -v -V; do
  check_exported "command $query lmline_export_lifetime_probe" ok
  check_exported "command $query lmline_export_absent_probe" ok
  check_exported "command $query unset; lmline_export_lifetime_probe" ok
  check_exported "unset -f lmline_export_lifetime_probe; command $query lmline_export_lifetime_probe" ok
  check_exported "bash -c 'command $query lmline_export_lifetime_probe'" ok
  check_exported "command $query lmline_export_lifetime_probe; lmline_export_absent_probe" command-not-found
done

# Fallback is a fresh builtin/PATH resolution, not a ban on the removed name.
# `false` is not in the policy skip list, so this really tests builtin lookup.
# shellcheck disable=SC2329
false() { touch "$caller_tmp/export-builtin-executed"; }
export -f false
check_exported 'unset -f false; false' ok
check_exported "unset -f false; bash -c 'false'" ok
check_exported "bash -c 'unset -f false; false'" ok
check_exported 'command false' ok
check_exported 'unset -f false; command false' ok
check_exported "bash -c 'command false'" ok
unset -f false
# Control the external namespace: macOS supplies a PATH executable `read`,
# unlike Linux. With no such executable, env must not accept the builtin via
# the skip list even though command can invoke it. Keep the child launcher
# and env available; no real read function is installed.
mkdir "$caller_tmp/builtin-only"
ln -s "$BASH" "$caller_tmp/builtin-only/bash"
ln -s "$(type -P env)" "$caller_tmp/builtin-only/env"
PATH="$caller_tmp/builtin-only" check_exported 'command read' ok
PATH="$caller_tmp/builtin-only" check_exported 'env read' command-not-found
# Adding a real external fallback must allow env without invoking that file.
cat >"$caller_tmp/builtin-only/read" <<EOF_STUB
#!/bin/sh
printf executed >"$caller_tmp/export-read-executed"
EOF_STUB
chmod +x "$caller_tmp/builtin-only/read"
PATH="$caller_tmp/builtin-only" check_exported 'env read' ok
cat >"$caller_tmp/lmline_export_path_probe" <<EOF_STUB
#!/bin/sh
touch "$caller_tmp/export-path-executed"
EOF_STUB
chmod +x "$caller_tmp/lmline_export_path_probe"
# shellcheck disable=SC2329
lmline_export_path_probe() { touch "$caller_tmp/export-path-function-executed"; }
export -f lmline_export_path_probe
for wrapper in '' command env; do
  PATH="$caller_tmp:$PATH" check_exported "unset -f lmline_export_path_probe; $wrapper lmline_export_path_probe" ok
  PATH="$caller_tmp:$PATH" check_exported "bash -c 'unset -f lmline_export_path_probe; $wrapper lmline_export_path_probe'" ok
  PATH="$caller_tmp:$PATH" check_exported "unset -f lmline_export_path_probe; bash -c '$wrapper lmline_export_path_probe'" ok
  PATH="$caller_tmp:$PATH" check_exported "$wrapper lmline_export_path_probe" ok
done
unset -f lmline_export_lifetime_probe lmline_export_unrelated_probe lmline_export_path_probe
# No exported names means the simple-command fast path is used; time option
# support/refusal must not depend on an unrelated inherited function existing.
check_exported 'time -p false' ok
check_exported 'time -x false' command-not-found
for marker in "$caller_tmp"/export-*-executed; do
  [[ ! -e "$marker" ]] || fail "exported-function validation executed a function or PATH stub: $marker"
done
ok "exported Bash functions use positional and wrapper-specific lookup without execution"
