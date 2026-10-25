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
  actual=$(LMLINE_SHELL_FUNCTIONS="$caller_list" __lmline_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target caller functions: $actual, expected $expected: $candidate (list: $caller_list)"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  # Active caller-shell function names are accepted as top-level commands,
  # including valid non-identifier punctuation and slash names.
  check_caller "$target" 'lmline_caller_probe_fn' ok 'lmline_caller_probe_fn'
  check_caller "$target" 'lmline-caller-probe' ok 'lmline-caller-probe'
  check_caller "$target" 'lmline_caller_dir/lmline-caller-probe' ok 'lmline_caller_dir/lmline-caller-probe'
  check_caller "$target" 'printf "$(lmline_caller_dir/lmline-caller-probe)"' ok 'lmline_caller_dir/lmline-caller-probe'
  check_caller "$target" 'lmline_caller_probe_fn --flag' ok 'lmline_caller_probe_fn'
  check_caller "$target" 'printf ok; lmline_caller_probe_fn' ok 'lmline_other_fn
lmline_caller_probe_fn'
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
__lmline_snapshot_caller_functions
[[ -z ${LMLINE_SHELL_FUNCTIONS-} ]] || fail "snapshot left the transport set"
[[ ${__LMLINE_CALLER_FUNCTIONS-} == 'lmline_snapshot_probe_fn' ]] || fail "snapshot lost the list"
actual=$(__lmline_candidate_rejection_reason 'lmline_snapshot_probe_fn' rewrite bash)
[[ "$actual" == ok ]] || fail "snapshot list was not accepted: $actual"
unset __LMLINE_CALLER_FUNCTIONS
actual=$(__lmline_candidate_rejection_reason 'lmline_snapshot_probe_fn' rewrite bash)
[[ "$actual" == command-not-found ]] || fail "unset snapshot still validates: $actual"
ok "snapshot captures and unsets the transport"
