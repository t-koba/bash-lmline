#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: definition names are syntax, but all function bodies and substitutions
# must be checked without defining or running any candidate function.
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

function_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-function-policy.XXXXXX")
trap 'rm -rf "$function_tmp"' EXIT

check_function() {
  local target=$1 candidate=$2 expected=$3 actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target function policy: $actual, expected $expected: $candidate"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  for header in 'function lmline_probe' 'lmline_probe()' 'lmline_probe ()' 'function lmline_probe()'; do
    check_function "$target" "$header { printf ok; }" ok
    check_function "$target" "$header { printf ok; }; lmline_probe" ok
    check_function "$target" "$header { lmline_missing_function_body; }" command-not-found
    check_function "$target" "$header { printf ok | lmline_missing_function_body; }" command-not-found
    check_function "$target" "$header { printf ok; }; lmline_undefined_function" command-not-found
    check_function "$target" "lmline_probe; $header { printf ok; }" command-not-found
    check_function "$target" "printf before; $header { pwd; }; printf after; lmline_probe" ok
    check_function "$target" "lmline_missing_before; $header { printf ok; }" command-not-found
    check_function "$target" "$header { printf ok; }; lmline_missing_after" command-not-found
    check_function "$target" "$header { printf '%s' \"\$(lmline_missing_function_substitution)\"; }" command-not-found
    check_function "$target" "$header { printf '%s' \"\$(printf ok)\"; }; printf '%s' \"\$(lmline_probe)\"" ok
    check_function "$target" "$header { case x in x) printf ok;; esac; }; lmline_probe" ok
    check_function "$target" "$header { case x in x) lmline_missing_function_case;; esac; }" command-not-found
    check_function "$target" "case x in x) $header { printf ok; }; lmline_probe;; esac" ok
    marker=$function_tmp/$target-executed
    check_function "$target" "$header { touch '$marker'; printf '%s' \"\$(touch '$marker')\"; }; lmline_probe" ok
    [[ ! -e "$marker" ]] || fail "$target candidate executed during function validation"
  done
  # Short-circuited definitions and pipeline members cannot establish a
  # function for a later parent-shell call. Both header forms use the same
  # syntax-only path; even apparently constant conditions are not evaluated.
  for header in 'lmline_probe()' 'function lmline_probe'; do
    check_function "$target" "false && $header { printf ok; }; lmline_probe" command-not-found
    check_function "$target" "true || $header { printf ok; }; lmline_probe" command-not-found
    check_function "$target" "$header { printf ok; } | cat; lmline_probe" command-not-found
    check_function "$target" "printf ok | $header { printf ok; }; lmline_probe" command-not-found
    check_function "$target" "false && { printf before; $header { printf ok; }; }; lmline_probe" command-not-found
    check_function "$target" "{ $header { printf ok; }; printf after; } | cat; lmline_probe" command-not-found
    check_function "$target" "$header { printf ok | cat; true && printf ok; }; lmline_probe" ok
    check_function "$target" "$header { printf ok; }; printf ok | cat; true && lmline_probe" ok
    check_function "$target" "printf ok | cat; true && printf ok; $header { printf ok; }; lmline_probe" ok
    check_function "$target" "case x in x|y) $header { printf ok | cat; }; lmline_probe;; esac" ok
    marker=$function_tmp/$target-list-executed
    check_function "$target" "true || $header { touch '$marker'; }; lmline_probe" command-not-found
    check_function "$target" "$header { touch '$marker'; } | cat; lmline_probe" command-not-found
    [[ ! -e "$marker" ]] || fail "$target candidate list executed during function validation"
  done
  if [[ "$target" == bash ]]; then
    check_function "$target" 'lmline_probe() { printf %s { }; printf fi }; }; lmline_probe' ok
  fi
  check_function "$target" 'lmline_probe() { if true; then printf ok; fi }; lmline_probe' ok
  check_function "$target" 'printf() { lmline_missing_function_body; }' command-not-found
  check_function "$target" 'function printf ( printf ok )' command-not-found
  check_function "$target" 'printf() ( printf ok )' command-not-found
  check_function "$target" 'lmline_probe() { printf ok; }; command lmline_probe' command-not-found
  actual=$(__lmline_candidate_rejection_reason 'lmline_probe() { printf ok;' rewrite "$target")
  [[ "$actual" == shell-syntax ]] || fail "$target malformed function was accepted: $actual"
  if __lmline_extract_command_words 'function lmline_probe' "$target" >/dev/null; then
    fail "$target unsupported incomplete function header was extracted"
  fi
  check_function "$target" 'lmline_first() { printf ok; }; lmline_second() { lmline_first; }; lmline_second' ok
  check_function "$target" 'printf "%s" "$(lmline_inner() { printf ok; }; lmline_inner)"' ok
  check_function "$target" 'printf "%s" "$(lmline_inner() { lmline_missing_inner; }; lmline_inner)"' command-not-found
  check_function "$target" 'printf "%s" "$(lmline_inner() { printf ok; })"; lmline_inner' command-not-found
  # Conditional definitions are scoped: a definition inside an if branch,
  # case branch, loop body or subshell is never available after that control
  # flow, though direct definitions and same-body calls still pass and bodies
  # are still checked.
  check_function "$target" 'if false; then lmline_probe() { printf ok; }; fi; lmline_probe' command-not-found
  check_function "$target" 'if false; then function lmline_probe { printf ok; }; fi; lmline_probe' command-not-found
  check_function "$target" 'if true; then lmline_probe() { printf ok; }; lmline_probe; fi' ok
  check_function "$target" 'if true; then lmline_probe() { lmline_missing_conditional_body; }; fi' command-not-found
  check_function "$target" 'case x in x) lmline_probe() { printf ok; };; esac; lmline_probe' command-not-found
  check_function "$target" 'for i in 1 2; do lmline_probe() { printf ok; }; done; lmline_probe' command-not-found
  check_function "$target" 'for i in 1 2; do lmline_probe() { printf ok; }; lmline_probe; done' ok
  check_function "$target" 'while true; do lmline_probe() { printf ok; }; done; lmline_probe' command-not-found
  check_function "$target" 'while true; do lmline_probe() { printf ok; }; lmline_probe; done' ok
  check_function "$target" '( lmline_probe() { printf ok; }; ); lmline_probe' command-not-found
  # Nested definitions stay inside their containing body: an inner name is
  # usable later in that body but never after an uncalled outer body.
  check_function "$target" 'lmline_probe() { printf ok; }; lmline_probe' ok
  check_function "$target" 'lmline_probe() { lmline_probe; }; lmline_probe' ok
  check_function "$target" 'lmline_outer() { lmline_inner() { printf ok; }; }; lmline_inner' command-not-found
  check_function "$target" 'function lmline_outer { lmline_inner() { printf ok; }; }; lmline_inner' command-not-found
  check_function "$target" 'lmline_outer() { lmline_inner() { printf ok; }; lmline_inner; }; lmline_outer' ok
  check_function "$target" 'lmline_outer() { lmline_missing_function_body; }; lmline_outer' command-not-found
  check_function "$target" 'lmline_outer() { lmline_inner() { lmline_missing_function_body; }; }; lmline_outer' command-not-found
  ok "$target function definitions and later calls are checked without execution"
done
