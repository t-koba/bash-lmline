#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: case selectors/patterns are data, but every body and substitution still
# needs an available command, even in branches that would not be selected.
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

case_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-case-policy.XXXXXX")
trap 'rm -rf "$case_tmp"' EXIT

check_case() {
  local target=$1 candidate=$2 expected=$3 extracted=${4-} actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_test_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target case policy: $actual, expected $expected: $candidate"
  if [[ -n "$extracted" ]]; then
    actual=$(__lmline_extract_command_words "$candidate" "$target" | paste -sd, -)
    [[ "$actual" == "$extracted" ]] || fail "$target case extraction: $actual, expected $extracted: $candidate"
  fi
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  check_case "$target" 'case x in x) printf ok;; esac' ok printf
  check_case "$target" 'case x in x|y) printf ok;; esac' ok printf
  check_case "$target" 'case "x y" in ("x y"|z) printf ok;; *) pwd;; esac' ok printf,pwd
  check_case "$target" "case x in 'x)'|x\\|y|[xy]*) printf ok;; *) :;; esac" ok printf,:
  check_case "$target" 'case x in x) printf ok; pwd;; y) :;; *) true;; esac; printf done' ok printf,pwd,:,true,printf
  check_case "$target" 'case x in x) lmline_missing_case_body_command;; esac' command-not-found lmline_missing_case_body_command
  check_case "$target" 'case x in x) printf ok;; y) lmline_missing_case_body_command;; esac' command-not-found printf,lmline_missing_case_body_command
  check_case "$target" 'case x in x) lmline_missing_case_body_command;; y) printf ok;; esac' command-not-found lmline_missing_case_body_command,printf
  check_case "$target" 'case x in x) printf ok | lmline_missing_case_body_command;; esac' command-not-found printf,lmline_missing_case_body_command
  check_case "$target" 'case x in x) case y in y|z) printf ok;; esac;; *) pwd;; esac' ok printf,pwd
  check_case "$target" 'case x in x) case y in y) lmline_missing_case_body_command;; esac;; esac' command-not-found lmline_missing_case_body_command
  check_case "$target" 'if true; then case x in x) printf ok; esac; fi' ok true,printf
  check_case "$target" 'printf case; case x in esac' ok printf
  check_case "$target" 'case "$(printf x)" in x) printf ok;; esac' ok printf,printf
  check_case "$target" 'case "$(lmline_missing_case_selector_command)" in x) printf ok;; esac' command-not-found printf,lmline_missing_case_selector_command
  check_case "$target" 'case "$(printf "%s" "$(lmline_missing_nested_case_command)")" in x) printf ok;; esac' command-not-found printf,printf,lmline_missing_nested_case_command
  check_case "$target" 'case "$(case x in x) printf x;; esac)" in x) printf ok;; esac' ok printf,printf
  check_case "$target" 'case x in "$(lmline_missing_case_pattern_command)"|x) printf ok;; esac' command-not-found printf,lmline_missing_case_pattern_command
  check_case "$target" 'case `printf x` in x) printf ok;; esac' ok printf,printf
  check_case "$target" 'case $((1 + 2)) in 3) printf ok;; esac' ok printf
  marker=$case_tmp/$target-executed
  candidate="case \"\$(printf '%s' \"\$(touch '$marker')\")\" in *) touch '$marker';; esac"
  check_case "$target" "$candidate" ok touch,printf,touch
  [[ ! -e "$marker" ]] || fail "$target candidate executed during case validation"
  check_case "$target" 'case x in x) printf ok;& y) lmline_missing_case_body_command;; esac' command-not-found printf,lmline_missing_case_body_command
  if [[ "$target" == bash ]]; then
    check_case "$target" 'case x in x) printf ok;;& y) lmline_missing_case_body_command;; esac' command-not-found printf,lmline_missing_case_body_command
  else
    check_case "$target" 'case x in x) print -r -- ok;| y) lmline_missing_case_body_command;; esac' command-not-found print,lmline_missing_case_body_command
    check_case "$target" 'case x in (x|y) print -r -- ok;; esac' ok print
  fi
  ok "$target case extraction checks every body and substitution without execution"
done
