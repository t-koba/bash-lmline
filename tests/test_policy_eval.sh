#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

# Risk: literal eval text hides command words, but validation must never run
# either that text or the substitutions used to construct a dynamic argument.
eval_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-eval-policy.XXXXXX")
trap 'rm -rf "$eval_tmp"' EXIT

check_eval() {
  local target=$1 candidate=$2 expected=$3 actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_test_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target eval policy: $actual, expected $expected: $candidate"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  check_eval "$target" "eval 'printf ok'" ok
  check_eval "$target" "eval 'printf ok' # trailing comment" ok
  check_eval "$target" "eval 'lmline_missing_eval'" command-not-found
  check_eval "$target" "eval 'lmline_missing_eval' # trailing comment" command-not-found
  check_eval "$target" "eval ''" ok
  check_eval "$target" "eval 'definitely-not-a-command-for-lmline'" command-not-found
  check_eval "$target" "eval 'printf ok | definitely-not-a-command-for-lmline'" command-not-found
  check_eval "$target" "eval 'case x in x) printf ok;; esac'" ok
  check_eval "$target" "eval 'case x in x) definitely-not-a-command-for-lmline;; esac'" command-not-found
  check_eval "$target" "eval 'printf \"\$(definitely-not-a-command-for-lmline)\"'" command-not-found
  # Outer syntax is valid; a recognized literal with invalid inner syntax is
  # not an available command, rather than being executed to discover its error.
  check_eval "$target" "eval 'if'" command-not-found
  check_eval "$target" "printf before; eval 'definitely-not-a-command-for-lmline'" command-not-found
  check_eval "$target" "eval 'printf ok'; printf after" ok
  check_eval "$target" "if true; then eval 'definitely-not-a-command-for-lmline'; fi" command-not-found
  check_eval "$target" "case x in x) eval 'definitely-not-a-command-for-lmline';; esac" command-not-found
  check_eval "$target" "lmline_probe() { printf ok; }; eval 'lmline_probe'" ok
  check_eval "$target" "lmline_probe() { eval 'definitely-not-a-command-for-lmline'; }" command-not-found
  check_eval "$target" "eval 'lmline_probe() { printf ok; }; lmline_probe'" ok
  check_eval "$target" "eval 'lmline_probe() { definitely-not-a-command-for-lmline; }; lmline_probe'" command-not-found

  check_eval "$target" "eval() { printf ok; }; eval 'lmline_missing_eval'" ok

  # Dynamic text, non-single-quoted forms, concatenation, multiple arguments,
  # options, wrappers and redirects are deliberately outside this recognizer.
  for candidate in \
    'eval "$lmline_dynamic_text"' \
    'eval "$(lmline_missing_eval)"' \
    'eval "lmline_missing_eval"' \
    "eval 'lmline_missing_eval'\"\$lmline_dynamic_text\"" \
    "eval 'lmline_missing_eval' ''" \
    "eval 'lmline_missing_eval' \"\$(lmline_missing_eval)\"" \
    "eval -- 'lmline_missing_eval'" \
    "command eval 'lmline_missing_eval'" \
    "eval 'lmline_missing_eval' >/dev/null" \
    "printf eval 'lmline_missing_eval'" \
    "printf ok # ; eval 'lmline_missing_eval'"; do
    check_eval "$target" "$candidate" ok
  done

  marker=$eval_tmp/$target-executed
  check_eval "$target" "eval 'touch \"$marker\"; printf \"\$(touch \"$marker-substitution\")\"'" ok
  check_eval "$target" "eval 'touch \"$marker\"; definitely-not-a-command-for-lmline'" command-not-found
  check_eval "$target" "eval \"\$(touch '$marker-dynamic')\"" ok
  [[ ! -e "$marker" && ! -e "$marker-substitution" && ! -e "$marker-dynamic" ]] || fail "$target eval validation executed candidate text"
  ok "$target literal eval availability and non-execution"
done

if command -v zsh >/dev/null 2>&1; then
  # Check the inner text with the target shell, including its reserved syntax
  # and builtins, rather than assuming Bash's parser or command table.
  check_eval zsh "eval 'repeat 2 print ok'" ok
  check_eval zsh "eval 'repeat 2 definitely-not-a-command-for-lmline'" command-not-found
  ok "zsh literal eval uses target syntax and builtins"
fi
