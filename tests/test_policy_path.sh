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

# A relative inherited PATH entry resolves against the current directory, so
# a direct directory change before a bare external that currently resolves
# only through such an entry is unreliable and fails closed. Syntax-only:
# candidates go only to `bash -n`/`zsh -f -n` and the validator, the inert
# stub is used only for `command -v` lookups and never runs.
check_cwd() {
  local target=$1 candidate=$2 expected=$3 actual
  if [[ "$target" == zsh ]]; then
    zsh -f -n -c "$candidate" || fail "invalid zsh fixture: $candidate"
  else
    bash -n -c "$candidate" || fail "invalid bash fixture: $candidate"
  fi
  actual=$(__lmline_candidate_rejection_reason "$candidate" rewrite "$target")
  [[ "$actual" == "$expected" ]] || fail "$target CWD policy: $actual, expected $expected: $candidate"
}

cwd_fixture=$path_tmp/cwd-fixture
cwd_empty=$path_tmp/cwd-empty
mkdir -p "$cwd_fixture" "$cwd_empty" || fail "CWD fixture setup"
printf '#!/bin/sh\nexit 0\n' > "$cwd_fixture/lmline_cwd_probe" || fail "CWD stub setup"
chmod +x "$cwd_fixture/lmline_cwd_probe" || fail "CWD stub setup"

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  orig_pwd=$PWD
  orig_path=$PATH
  cd "$cwd_fixture" || fail "$target CWD fixture cd"
  export PATH=".:$orig_path"
  # Lookup-only fixture proof: the stub resolves here through `.` ...
  command -v lmline_cwd_probe >/dev/null 2>&1 || fail "$target CWD fixture lookup"
  # ... and a separate controlled directory change loses it.
  cd "$cwd_empty" || fail "$target CWD empty cd"
  command -v lmline_cwd_probe >/dev/null 2>&1 && fail "$target CWD lookup should fail after cd"
  cd "$cwd_fixture" || fail "$target CWD fixture cd"
  # The observed false acceptance: direct cd before a relative-only lookup.
  check_cwd "$target" "cd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  if [[ "$target" == bash ]]; then
    # Existing hash entries can also retain relative command paths after cd.
    (
      builtin hash -p ./lmline_cwd_probe lmline_cwd_probe
      check_cwd "$target" "cd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
    )
  fi
  check_cwd "$target" "pushd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  check_cwd "$target" "popd; lmline_cwd_probe" command-not-found
  check_cwd "$target" "command cd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  check_cwd "$target" "builtin cd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd \"$cwd_empty\" && lmline_cwd_probe" command-not-found
  check_cwd "$target" "> /dev/null cd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  # Dynamic same-shell code and traps can change cwd before later commands;
  # these forms fail closed without evaluating their bodies.
  check_cwd "$target" "eval 'cd \"$cwd_empty\"'; lmline_cwd_probe" command-not-found
  check_cwd "$target" "source /dev/null; lmline_cwd_probe" command-not-found
  check_cwd "$target" "trap 'cd \"$cwd_empty\"' DEBUG; lmline_cwd_probe" command-not-found
  if [[ "$target" == zsh ]]; then
    check_cwd "$target" "chdir \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  fi
  # PATH-independent commands stay available after the same change.
  check_cwd "$target" "cd \"$cwd_empty\"; ls" ok
  check_cwd "$target" "cd \"$cwd_empty\"; read" ok
  check_cwd "$target" "cd \"$cwd_empty\"; /bin/ls" ok
  check_cwd "$target" "cd \"$cwd_empty\"; echo hi" ok
  # No preceding change, or the lookup precedes the change: still available.
  check_cwd "$target" "lmline_cwd_probe" ok
  check_cwd "$target" "lmline_cwd_probe; cd \"$cwd_empty\"" ok
  # Quoted data and comments never contribute a change or a lookup.
  check_cwd "$target" "printf 'cd; lmline_cwd_probe'" ok
  check_cwd "$target" "printf ok # ; cd $cwd_empty; lmline_cwd_probe" ok
  # An empty PATH component is the current directory too.
  export PATH=":$orig_path"
  command -v lmline_cwd_probe >/dev/null 2>&1 || fail "$target CWD empty-entry lookup"
  check_cwd "$target" "cd \"$cwd_empty\"; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd \"$cwd_empty\"; ls" ok
  # Fail closed when a relative entry shadows an absolute fallback; the
  # command's current resolution may change after cd. The stub is lookup-only.
  printf '#!/bin/sh\nexit 0\n' > "$cwd_fixture/ls" || fail "$target CWD fallback stub setup"
  chmod +x "$cwd_fixture/ls" || fail "$target CWD fallback stub setup"
  (
    builtin hash -r
    check_cwd "$target" "cd \"$cwd_empty\"; ls" command-not-found
  )
  rm -f "$cwd_fixture/ls"
  check_cwd "$target" "cd \"$cwd_empty\"; ls" ok
  export PATH=".:$orig_path"
  cwd_marker=$path_tmp/$target-cwd-executed
  cwd_marker_ok=$path_tmp/$target-cwd-executed-ok
  rm -f "$cwd_marker" "$cwd_marker_ok"
  check_cwd "$target" "cd \"$cwd_empty\"; touch \"$cwd_marker\"" ok
  check_cwd "$target" "cd \"$cwd_empty\"; lmline_cwd_probe; touch \"$cwd_marker_ok\"" command-not-found
  [[ ! -e "$cwd_marker" && ! -e "$cwd_marker_ok" ]] || fail "$target CWD validation executed candidate text"
  cd "$orig_pwd" || fail "$target CWD restore cd"
  export PATH="$orig_path"
  ok "$target relative-PATH directory-change handling and non-execution"
done

ok "PATH-prefix availability"
