#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

# Risk: literal trap action text hides command words, but validation must never
# run either that text or the substitutions used to construct a dynamic action.
trap_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-trap-policy.XXXXXX")
trap 'rm -rf "$trap_tmp"' EXIT

check_trap() {
  local target=$1 candidate=$2 expected=$3 actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_test_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target trap policy: $actual, expected $expected: $candidate"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  check_trap "$target" "trap 'printf ok' EXIT" ok
  check_trap "$target" "trap 'printf ok' EXIT INT" ok
  check_trap "$target" "trap 'printf ok' EXIT # trailing comment" ok
  check_trap "$target" "trap '' EXIT" ok
  check_trap "$target" "trap '-' EXIT" ok
  check_trap "$target" "trap 'definitely-not-a-command-for-lmline' EXIT" command-not-found
  check_trap "$target" "trap 'definitely-not-a-command-for-lmline' EXIT # trailing comment" command-not-found
  check_trap "$target" "trap 'printf ok | definitely-not-a-command-for-lmline' EXIT" command-not-found
  check_trap "$target" "trap 'case x in x) printf ok;; esac' EXIT" ok
  check_trap "$target" "trap 'case x in x) definitely-not-a-command-for-lmline;; esac' EXIT" command-not-found
  check_trap "$target" "trap 'printf \"\$(definitely-not-a-command-for-lmline)\"' EXIT" command-not-found
  # Outer syntax is valid; a recognized literal with invalid inner syntax is
  # not an available command, rather than being executed to discover its error.
  check_trap "$target" "trap 'if' EXIT" command-not-found
  check_trap "$target" "printf before; trap 'definitely-not-a-command-for-lmline' EXIT" command-not-found
  check_trap "$target" "trap 'printf ok' EXIT; printf after" ok
  check_trap "$target" "if true; then trap 'definitely-not-a-command-for-lmline' EXIT; fi" command-not-found
  check_trap "$target" "case x in x) trap 'definitely-not-a-command-for-lmline' EXIT;; esac" command-not-found
  check_trap "$target" "lmline_probe() { printf ok; }; trap 'lmline_probe' EXIT" ok
  check_trap "$target" "lmline_probe() { trap 'definitely-not-a-command-for-lmline' EXIT; }" command-not-found
  check_trap "$target" "trap 'lmline_probe() { printf ok; }; lmline_probe' EXIT" ok
  check_trap "$target" "trap 'lmline_probe() { definitely-not-a-command-for-lmline; }; lmline_probe' EXIT" command-not-found

  check_trap "$target" "trap() { printf ok; }; trap 'lmline_missing_trap' EXIT" ok

  # Dynamic text, non-single-quoted forms, concatenation, missing signals,
  # options, wrappers and non-command positions are deliberately outside this
  # recognizer.
  for candidate in \
    'trap "$lmline_dynamic_text" EXIT' \
    'trap "$(lmline_missing_trap)" EXIT' \
    'trap "lmline_missing_trap" EXIT' \
    "trap 'lmline_missing_trap'\"\$lmline_dynamic_text\" EXIT" \
    "trap 'lmline_missing_trap'" \
    "trap 'lmline_missing_trap' # trailing comment" \
    "trap -- 'lmline_missing_trap' EXIT" \
    "command trap 'lmline_missing_trap' EXIT" \
    "printf trap 'lmline_missing_trap'" \
    "printf ok # ; trap 'lmline_missing_trap' EXIT"; do
    check_trap "$target" "$candidate" ok
  done

  marker=$trap_tmp/$target-executed
  check_trap "$target" "trap 'touch \"$marker\"; printf \"\$(touch \"$marker-substitution\")\"' EXIT" ok
  check_trap "$target" "trap 'touch \"$marker\"; definitely-not-a-command-for-lmline' EXIT" command-not-found
  check_trap "$target" "trap \"\$(touch '$marker-dynamic')\" EXIT" ok
  [[ ! -e "$marker" && ! -e "$marker-substitution" && ! -e "$marker-dynamic" ]] || fail "$target trap validation executed candidate text"
  ok "$target literal trap availability and non-execution"
done

if command -v zsh >/dev/null 2>&1; then
  # Check the inner text with the target shell, including its reserved syntax
  # and builtins, rather than assuming Bash's parser or command table.
  check_trap zsh "trap 'repeat 2 print ok' EXIT" ok
  check_trap zsh "trap 'repeat 2 definitely-not-a-command-for-lmline' EXIT" command-not-found
  ok "zsh literal trap uses target syntax and builtins"
fi
