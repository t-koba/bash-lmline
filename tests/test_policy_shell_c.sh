#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

# Risk: literal shell -c text hides command words, but validation must never
# run either that text or the substitutions used to construct a dynamic argument.
shellc_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-shellc-policy.XXXXXX")
trap 'rm -rf "$shellc_tmp"' EXIT

check_shellc() {
  local target=$1 candidate=$2 expected=$3 actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target shell-c policy: $actual, expected $expected: $candidate"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  check_shellc "$target" "bash -c 'printf ok'" ok
  check_shellc "$target" "bash -c 'printf ok' # trailing comment" ok
  check_shellc "$target" "bash -c ''" ok
  check_shellc "$target" "bash -c 'definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -x -c 'definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -eu -c 'definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -v -e -u -x -c 'printf ok'" ok
  check_shellc "$target" "bash -c 'definitely-not-a-command-for-lmline' # trailing comment" command-not-found
  check_shellc "$target" "bash -c 'printf ok | definitely-not-a-command-for-lmline'" command-not-found
  # A batched availability probe must still reject a missing word after
  # available words in the same literal script.
  check_shellc "$target" "bash -c 'printf ok; printf ok; definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -c 'case x in x) printf ok;; esac'" ok
  check_shellc "$target" "bash -c 'case x in x) definitely-not-a-command-for-lmline;; esac'" command-not-found
  check_shellc "$target" "bash -c 'printf \"\$(definitely-not-a-command-for-lmline)\"'" command-not-found
  # Outer syntax is valid; a recognized literal with invalid inner syntax is
  # not an available command, rather than being executed to discover its error.
  check_shellc "$target" "bash -c 'if'" command-not-found
  check_shellc "$target" "printf before; bash -c 'definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -c 'printf ok'; printf after" ok
  check_shellc "$target" "if true; then bash -c 'definitely-not-a-command-for-lmline'; fi" command-not-found
  check_shellc "$target" "case x in x) bash -c 'definitely-not-a-command-for-lmline';; esac" command-not-found
  check_shellc "$target" "lmline_probe() { printf ok; }; bash -c 'lmline_probe'" command-not-found
  check_shellc "$target" "bash -c 'lmline_probe() { printf ok; }; lmline_probe'" ok
  check_shellc "$target" "bash -c 'lmline_probe() { definitely-not-a-command-for-lmline; }; lmline_probe'" command-not-found

  check_shellc "$target" "bash() { printf ok; }; bash -c 'lmline_missing_shellc'" ok

  # Caller-shell functions are not visible inside the invoked shell: the
  # validator must not short-circuit availability with its own `command -v`.
  # Only the quoted word is probed in a fresh shell; nothing here runs it.
  # shellcheck disable=SC2329 # looked up indirectly by the nested-shell validator
  lmline_caller_only_shellc_fn() { :; }
  check_shellc "$target" "bash -c 'lmline_caller_only_shellc_fn'" command-not-found
  unset -f lmline_caller_only_shellc_fn
  # An exported function travels with the environment, so the invoked Bash
  # still resolves it.
  # shellcheck disable=SC2329 # looked up indirectly by the nested-shell validator
  lmline_exported_shellc_fn() { :; }
  export -f lmline_exported_shellc_fn
  check_shellc "$target" "bash -c 'lmline_exported_shellc_fn'" ok
  export -n -f lmline_exported_shellc_fn 2>/dev/null || true
  unset -f lmline_exported_shellc_fn

  if command -v zsh >/dev/null 2>&1; then
    check_shellc "$target" "zsh -f -c 'printf ok'" ok
    check_shellc "$target" "zsh -f -c 'printf ok' # trailing comment" ok
    check_shellc "$target" "zsh -f -c ''" ok
    check_shellc "$target" "zsh -f -c 'definitely-not-a-command-for-lmline'" command-not-found
    check_shellc "$target" "zsh -f -c 'definitely-not-a-command-for-lmline' # trailing comment" command-not-found
    check_shellc "$target" "zsh -f -c 'printf ok | definitely-not-a-command-for-lmline'" command-not-found
    check_shellc "$target" "zsh -f -c 'if'" command-not-found
    check_shellc "$target" "printf before; zsh -f -c 'definitely-not-a-command-for-lmline'" command-not-found
    check_shellc "$target" "lmline_probe() { printf ok; }; zsh -f -c 'lmline_probe'" command-not-found
    # shellcheck disable=SC2329 # looked up indirectly by the nested-shell validator
    lmline_caller_only_zshc_fn() { :; }
    check_shellc "$target" "zsh -f -c 'lmline_caller_only_zshc_fn'" command-not-found
    unset -f lmline_caller_only_zshc_fn
    check_shellc "$target" "zsh -f -c 'lmline_probe() { printf ok; }; lmline_probe'" ok
    check_shellc "$target" "zsh() { printf ok; }; zsh -f -c 'lmline_missing_shellc'" ok
  fi

  # Dynamic text, non-single-quoted forms, concatenation, extra operands,
  # unallowlisted options, wrappers and redirects remain outside this recognizer.
  for candidate in \
    'bash -c "$lmline_dynamic_text"' \
    'bash -c "$(lmline_missing_shellc)"' \
    'bash -c "lmline_missing_shellc"' \
    "bash -c 'lmline_missing_shellc'\"\$lmline_dynamic_text\"" \
    "bash -c 'lmline_missing_shellc'#suffix" \
    "bash -c 'lmline_missing_shellc' ''" \
    "bash -c 'lmline_missing_shellc' \"\$(lmline_missing_shellc)\"" \
    "bash -c 'lmline_missing_shellc' extra" \
    "bash -o pipefail -c 'lmline_missing_shellc'" \
    "bash -- -c 'lmline_missing_shellc'" \
    "command bash -c 'lmline_missing_shellc'" \
    "sudo bash -c 'lmline_missing_shellc'" \
    "/bin/bash -c 'lmline_missing_shellc'" \
    "bash -c 'lmline_missing_shellc' >/dev/null" \
    "printf bash -c 'lmline_missing_shellc'" \
    "printf ok # ; bash -c 'lmline_missing_shellc'"; do
    check_shellc "$target" "$candidate" ok
  done

  if command -v zsh >/dev/null 2>&1; then
    for candidate in \
      'zsh -f -c "$lmline_dynamic_text"' \
      'zsh -f -c "lmline_missing_shellc"' \
      "zsh -f -c 'lmline_missing_shellc'#suffix" \
      "zsh -f -c 'lmline_missing_shellc' extra" \
      "zsh -c 'lmline_missing_shellc'" \
      "zsh -f -x -c 'lmline_missing_shellc'" \
      "zsh -c -f 'lmline_missing_shellc'" \
      "command zsh -f -c 'lmline_missing_shellc'" \
      "zsh -f -c 'lmline_missing_shellc' >/dev/null"; do
      check_shellc "$target" "$candidate" ok
    done
  fi

  marker=$shellc_tmp/$target-executed
  check_shellc "$target" "bash -c 'touch \"$marker\"; printf \"\$(touch \"$marker-substitution\")\"'" ok
  check_shellc "$target" "bash -x -c 'touch \"$marker\"; printf \"\$(touch \"$marker-substitution\")\"'" ok
  check_shellc "$target" "bash -e -c 'touch \"$marker\"; definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -c 'touch \"$marker\"; definitely-not-a-command-for-lmline'" command-not-found
  check_shellc "$target" "bash -c \"\$(touch '$marker-dynamic')\"" ok
  if command -v zsh >/dev/null 2>&1; then
    check_shellc "$target" "zsh -f -c 'touch \"$marker-zsh\"; printf \"\$(touch \"$marker-zsh-substitution\")\"'" ok
    check_shellc "$target" "zsh -f -c 'touch \"$marker-zsh\"; definitely-not-a-command-for-lmline'" command-not-found
  fi
  [[ ! -e "$marker" && ! -e "$marker-substitution" && ! -e "$marker-dynamic" ]] || fail "$target shell-c validation executed candidate text"
  [[ ! -e "$marker-zsh" && ! -e "$marker-zsh-substitution" ]] || fail "$target shell-c validation executed candidate text"
  ok "$target literal shell-c availability and non-execution"
done

if command -v zsh >/dev/null 2>&1; then
  # Check the inner text with the invoked shell, including its reserved syntax
  # and builtins, rather than assuming Bash's parser or command table.
  check_shellc bash "zsh -f -c 'print ok'" ok
  check_shellc bash "zsh -f -c 'repeat 2 print ok'" ok
  check_shellc bash "zsh -f -c 'repeat 2 definitely-not-a-command-for-lmline'" command-not-found
  check_shellc bash "zsh -f -c 'case x in x) printf ok;; esac'" ok
  ok "invoked-shell shell-c uses target syntax and builtins"
fi
