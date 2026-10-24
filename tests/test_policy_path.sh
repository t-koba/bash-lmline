#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

# Availability under a literal command-prefix PATH assignment is syntax-only:
# only target-shell `command -v` probes run, the candidate text never runs.
path_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-path-policy.XXXXXX")
trap 'rm -rf "$path_tmp"' EXIT

check_path() {
  local target=$1 candidate=$2 expected=$3 actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target PATH policy: $actual, expected $expected: $candidate"
}

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  # The extractor output stays compatible: the prefix is skipped, the command
  # word is still reported.
  [[ $(__lmline_extract_command_words 'PATH=/nonexistent ls' "$target") == ls ]] \
    || fail "$target PATH extraction compat: PATH=/nonexistent ls"
  # Required regressions: unavailable external rejected, literal PATH with a
  # known directory accepted, builtin under the same prefix accepted.
  check_path "$target" 'PATH=/nonexistent ls' command-not-found
  check_path "$target" 'PATH=/usr/bin:/bin ls' ok
  check_path "$target" 'PATH=/nonexistent read' ok
  if [[ "$target" == zsh ]]; then
    # Zsh ties lowercase `path` to its PATH search array.
    check_path "$target" 'path=/nonexistent ls' command-not-found
    check_path "$target" 'path=/usr/bin:/bin ls' ok
    check_path "$target" 'path=/nonexistent read' ok
  else
    # In Bash, lowercase `path` is an ordinary variable.
    check_path "$target" 'path=/nonexistent ls' ok
  fi
  # Structural-looking separators inside quoted arguments or comments remain
  # data; they do not make a direct PATH prefix ambiguous.
  check_path "$target" "PATH=/usr/bin:/bin printf 'a;b|c'" ok
  check_path "$target" 'PATH=/usr/bin:/bin printf ok # ; PATH=/nonexistent ls' ok
  # PATH text is data outside a command-prefix position, including quoted
  # command names and comments containing apparent list boundaries.
  check_path "$target" "printf 'PATH=/nonexistent ls'" ok
  check_path "$target" 'printf PATH=/nonexistent' ok
  check_path "$target" "'printf' 'PATH=/nonexistent ls'" ok
  check_path "$target" 'printf ok # PATH=/nonexistent ls' ok
  check_path "$target" 'printf ok # ; PATH=/nonexistent ls' ok
  check_path "$target" "printf 'ok; PATH=/nonexistent ls'" ok
  check_path "$target" 'command env PATH=/nonexistent ls' command-not-found
  check_path "$target" '/usr/bin/env PATH=/nonexistent ls' command-not-found
  # Wrappers are deliberately unsupported: their own lookup and the child's
  # environment cannot be conflated. Even a valid inner PATH cannot hide an
  # unavailable outer env. No wrapper or external candidate is executed.
  check_path "$target" 'env PATH=/nonexistent ls' command-not-found
  check_path "$target" 'env PATH=/usr/bin:/bin ls' command-not-found
  check_path "$target" 'PATH=/nonexistent env PATH=/usr/bin ls' command-not-found
  check_path "$target" 'PATH=/usr/bin:/bin env PATH=/usr/bin:/bin ls' command-not-found
  # Dynamic PATH cannot affect builtin lookup. Opaque values are never expanded.
  check_path "$target" 'PATH=$HOME/bin read' ok
  check_path "$target" 'PATH=/usr/bin:$PATH read' ok
  check_path "$target" 'PATH+=/usr/bin read' ok
  check_path "$target" 'PATH="$HOME/bin" read' ok
  check_path "$target" 'PATH=$HOME/bin ls' command-not-found
  check_path "$target" 'PATH=/usr/bin:$PATH ls' command-not-found
  check_path "$target" 'PATH=~/bin ls' command-not-found
  check_path "$target" 'PATH+=/usr/bin ls' command-not-found
  check_path "$target" 'PATH=/nonexistent /bin/ls' ok
  check_path "$target" 'PATH=$HOME/bin /bin/ls' ok
  # Quoted literal values are opaque, not mistaken for an empty PATH.
  check_path "$target" "PATH='/usr/bin:/bin' ls" command-not-found
  check_path "$target" "PATH='/nonexistent' read" ok
  # Compound/persistent, nested-code and additional-assignment forms fail closed.
  check_path "$target" 'PATH=/nonexistent; ls' command-not-found
  check_path "$target" 'PATH=/usr/bin:/bin OTHER=value ls' command-not-found
  check_path "$target" "PATH=/usr/bin:/bin bash -c 'ls'" command-not-found
  check_path "$target" "bash -c 'PATH=/nonexistent ls'" command-not-found
  check_path "$target" "PATH=/nonexistent /bin/sh -c 'ls'" command-not-found
  check_path "$target" 'PATH=/nonexistent /usr/bin/env PATH=/usr/bin ls' command-not-found
  check_path "$target" "PATH=\$HOME/bin eval 'ls'" command-not-found
  check_path "$target" 'PATH=$(printf /usr/bin) ls' command-not-found
  check_path "$target" 'PATH=/nonexistent ls; printf ok' command-not-found
  check_path "$target" 'printf ok; PATH=/nonexistent ls' command-not-found
  # Redirections before the command do not hide a PATH assignment.
  check_path "$target" '> /dev/null PATH=/nonexistent ls' command-not-found
  check_path "$target" '2>/dev/null PATH=/nonexistent ls' command-not-found

  marker=$path_tmp/$target-executed
  rm -f "$marker" "$marker-ok"
  check_path "$target" "PATH=/nonexistent touch \"$marker\"" command-not-found
  check_path "$target" "PATH=/usr/bin:/bin touch \"$marker-ok\"" ok
  [[ ! -e "$marker" && ! -e "$marker-ok" ]] || fail "$target PATH validation executed candidate text"
  ok "$target PATH-prefix availability and non-execution"
done

ok "PATH-prefix availability"
