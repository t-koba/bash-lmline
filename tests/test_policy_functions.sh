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
  # A declaration-only installer transfers only its immediate children after
  # the immediately following standalone call, without running any candidate.
  for header in 'lmline_outer()' 'function lmline_outer'; do
    installer="$header { lmline_inner() { printf ok; }; }"
    check_function "$target" "$installer; lmline_outer; lmline_inner" ok
    check_function "$target" "$installer; lmline_inner" command-not-found
    check_function "$target" "$header { lmline_inner() { printf ok; }; function lmline_second { pwd; }; }; lmline_outer; lmline_inner; lmline_second" ok
    check_function "$target" "$header { lmline_inner() { lmline_grandchild() { printf ok; }; }; }; lmline_outer; lmline_inner" ok
    check_function "$target" "$header { lmline_inner() { lmline_grandchild() { printf ok; }; }; }; lmline_outer; lmline_grandchild" command-not-found
    check_function "$target" "$header { lmline_inner() { lmline_grandchild() { printf ok; }; }; }; lmline_outer; lmline_inner; lmline_grandchild" command-not-found
    for statement in 'printf before' 'return' 'true'; do
      check_function "$target" "$header { $statement; lmline_inner() { printf ok; }; }; lmline_outer; lmline_inner" command-not-found
    done
    check_function "$target" "$header { lmline_inner() { printf ok; }; return; }; lmline_outer; lmline_inner" command-not-found
    check_function "$target" "$header { lmline_inner() { lmline_missing_nested_body; }; }; lmline_outer; lmline_inner" command-not-found
    marker=$function_tmp/$target-installer-executed
    check_function "$target" "$header { lmline_inner() { touch '$marker'; printf '%s' \"\$(touch '$marker')\"; }; }; lmline_outer; lmline_inner" ok
    [[ ! -e "$marker" ]] || fail "$target installer candidate executed during validation"
  done
  installer='lmline_outer() { lmline_inner() { printf ok; }; }'
  # No arguments, redirects, prefixes, list operators or intervening commands.
  for call in 'lmline_outer arg' 'lmline_outer >/dev/null' 'LMLINE_TEST=1 lmline_outer' \
    'time lmline_outer' 'command lmline_outer' 'env lmline_outer' \
    'true && lmline_outer' 'false || lmline_outer' 'lmline_outer && true' \
    'lmline_outer || true' 'lmline_outer | cat' 'printf ok | lmline_outer' \
    'printf before; lmline_outer' 'unset -f lmline_outer; lmline_outer' \
    'lmline_outer() { printf replacement; }; lmline_outer'; do
    check_function "$target" "$installer; $call; lmline_inner" command-not-found
  done
  if [[ "$target" == bash ]]; then
    # Zsh's -n reports the negated status even without executing the command.
    check_function "$target" "$installer; ! lmline_outer; lmline_inner" command-not-found
  fi
  check_function "$target" "$installer; lmline_outer & lmline_inner" command-not-found
  check_function "$target" "$installer >/dev/null; lmline_outer; lmline_inner" command-not-found
  for body in 'if true; then lmline_inner() { printf ok; }; fi' \
    'for i in 1; do lmline_inner() { printf ok; }; done' \
    '{ lmline_inner() { printf ok; }; }' \
    'lmline_inner() { printf ok; } >/dev/null'; do
    check_function "$target" "lmline_outer() { $body; }; lmline_outer; lmline_inner" command-not-found
  done
  # Transfers are useful within the current analysis body, never across it.
  sequence="$installer; lmline_outer; lmline_inner"
  check_function "$target" "if true; then $sequence; fi" ok
  check_function "$target" "case x in x) $sequence;; esac" ok
  check_function "$target" "for i in 1; do $sequence; done" ok
  check_function "$target" "( $sequence )" ok
  check_function "$target" "lmline_caller() { $sequence; }; lmline_caller" ok
  for body in "if true; then $sequence; fi" "case x in x) $sequence;; esac" \
    "for i in 1; do $sequence; done" "( $sequence )" \
    "lmline_caller() { $sequence; }; lmline_caller"; do
    check_function "$target" "$body; lmline_inner" command-not-found
  done
  check_function "$target" "if true; then $installer; fi; lmline_outer; lmline_inner" command-not-found
  check_function "$target" "$installer; if true; then lmline_outer; fi; lmline_inner" command-not-found
  # Conditions precede the existing then/do scope save; no transfer may seed
  # that save and thereby escape the containing conditional or loop.
  check_function "$target" "if true; $installer; lmline_outer; then printf ok; fi; lmline_inner" command-not-found
  check_function "$target" "while false; $installer; lmline_outer; do printf ok; done; lmline_inner" command-not-found
  check_function "$target" "until true; $installer; lmline_outer; do printf ok; done; lmline_inner" command-not-found
  check_function "$target" "if { $installer; lmline_outer; }; then printf ok; fi; lmline_inner" command-not-found
  check_function "$target" "while { $installer; lmline_outer; }; do printf ok; done; lmline_inner" command-not-found
  ok "$target function definitions and later calls are checked without execution"
done
