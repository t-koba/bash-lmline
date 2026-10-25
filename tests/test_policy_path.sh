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
cwd_probe_marker=$path_tmp/cwd-probe-executed
printf '#!/bin/sh\ntouch "%s"\n' "$cwd_probe_marker" > "$cwd_fixture/lmline_cwd_probe" || fail "CWD stub setup"
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
  # Only a proven flat simple pipeline isolates non-final cwd changes.
  # Siblings and the enclosing list retain their original cwd; a final cd
  # remains conservative for Bash lastpipe and Zsh's pipeline semantics.
  check_cwd "$target" "cd $cwd_empty | true; lmline_cwd_probe" ok
  # Empty quote fragments on a bare lookup do not erase proven isolation of
  # a non-final pipeline cd; nonempty quoted structure stays conservative.
  check_cwd "$target" "cd $cwd_empty | true; lmline_cwd_probe''" ok
  check_cwd "$target" "cd $cwd_empty | true; lmline_cwd_probe\"\"" ok
  check_cwd "$target" "cd \"$cwd_empty\" | true; lmline_cwd_probe''" command-not-found
  check_cwd "$target" "cd $cwd_empty | cd $cwd_empty | true; lmline_cwd_probe" ok
  check_cwd "$target" "cd $cwd_empty | lmline_cwd_probe; lmline_cwd_probe" ok
  check_cwd "$target" "cd $cwd_empty | true; ./lmline_cwd_probe" ok
  check_cwd "$target" "cd $cwd_empty; lmline_cwd_probe" command-not-found
  # Fragmented cd remains an opaque possible cwd change for the PATH guard.
  check_cwd "$target" "cd'' $cwd_empty; lmline_cwd_probe" command-not-found
  # Fragmented lookups keep their static resolution, but must still be checked
  # against a prior possible cwd change before that resolution is trusted.
  check_cwd "$target" "lmline_cwd_probe''" ok
  check_cwd "$target" "cd $cwd_empty; lmline_cwd_probe''" command-not-found
  check_cwd "$target" "cd'' $cwd_empty; lmline_cwd_probe''" command-not-found
  check_cwd "$target" "cd $cwd_empty && lmline_cwd_probe" command-not-found
  check_cwd "$target" "true | cd $cwd_empty; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty; true | true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty; lmline_cwd_probe | true" command-not-found
  check_cwd "$target" "cd $cwd_empty; cd $cwd_empty | true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty; ./lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty; $cwd_fixture/lmline_cwd_probe" ok
  # Compound, grouped and otherwise ambiguous forms keep the old scan.
  check_cwd "$target" "{ cd $cwd_empty; lmline_cwd_probe; } | true" command-not-found
  check_cwd "$target" "{ cd $cwd_empty; } | true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "(cd $cwd_empty; lmline_cwd_probe) | true" command-not-found
  check_cwd "$target" "if true; then cd $cwd_empty | true; fi; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty |& true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty | true && lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty | true || lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty | true & lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd \"$cwd_empty\" | true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "c\\d $cwd_empty | true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty > /dev/null | true; lmline_cwd_probe" command-not-found
  check_cwd "$target" "cd $cwd_empty | true; lmline_cwd_probe # comment" command-not-found
  if [[ "$target" == zsh ]]; then
    check_cwd "$target" "chdir $cwd_empty | true; lmline_cwd_probe" ok
    check_cwd "$target" "cd $cwd_empty | true *(N); lmline_cwd_probe" command-not-found
  fi
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
  check_cwd "$target" "cd $cwd_empty | true; lmline_cwd_probe; touch $cwd_marker_ok" ok
  [[ ! -e "$cwd_probe_marker" ]] || fail "$target CWD validation executed lookup stub"
  [[ ! -e "$cwd_marker" && ! -e "$cwd_marker_ok" ]] || fail "$target CWD validation executed candidate text"
  cd "$orig_pwd" || fail "$target CWD restore cd"
  export PATH="$orig_path"
  ok "$target relative-PATH directory-change handling and non-execution"
done

# Explicit slash-containing command paths are validated against the filesystem
# only (-f/-x metadata, symlinks followed); candidates go only to the
# target-shell syntax parser and the static validator, inert stubs are only
# inspected, never executed.
slash_dir=$path_tmp/slash-fixture
slash_empty=$path_tmp/slash-empty
mkdir -p "$slash_dir" "$slash_empty" || fail "slash fixture setup"
slash_probe_marker=$slash_dir/probe-executed
rm -f "$slash_probe_marker"
printf '#!/bin/sh\ntouch "%s"\n' "$slash_probe_marker" > "$slash_dir/lmline_slash_exe" || fail "slash stub setup"
chmod +x "$slash_dir/lmline_slash_exe" || fail "slash stub setup"
ln -s "$slash_dir/lmline_slash_exe" "$slash_dir/has space" || fail "slash space setup"
printf 'data\n' > "$slash_dir/lmline_slash_noexec" || fail "slash fixture setup"
chmod -x "$slash_dir/lmline_slash_noexec" || fail "slash fixture setup"
mkdir -p "$slash_dir/lmline_slash_dir" || fail "slash fixture setup"
ln -s "$slash_dir/lmline_slash_exe" "$slash_dir/lmline_slash_link_ok" || fail "slash link setup"
ln -s /no/such/lmline_missing_link_target "$slash_dir/lmline_slash_link_bad" || fail "slash link setup"
ln -s "$slash_dir/lmline_slash_dir" "$slash_dir/lmline_slash_link_dir" || fail "slash link setup"

for target in bash zsh; do
  if [[ "$target" == zsh ]] && ! command -v zsh >/dev/null 2>&1; then
    continue
  fi
  # Reproduced false acceptances: unavailable slash paths were accepted, and
  # quoted slash paths were skipped entirely.
  check_path "$target" '/no/such/lmline_missing_executable' command-not-found
  check_path "$target" './lmline_missing_executable' command-not-found
  check_path "$target" 'dir/lmline_missing_executable' command-not-found
  check_path "$target" '"/no/such/lmline_missing_executable"' command-not-found
  check_path "$target" "'/no/such/lmline_missing_executable'" command-not-found
  # Filesystem truth: executable, non-executable, directory, symlinks.
  check_path "$target" "$slash_dir/lmline_slash_exe" ok
  check_path "$target" "'$slash_dir/lmline_slash_exe'" ok
  check_path "$target" "\"$slash_dir/lmline_slash_exe\"" ok
  check_path "$target" "$slash_dir/lmline_slash_noexec" command-not-found
  check_path "$target" "'$slash_dir/lmline_slash_noexec'" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_dir" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_link_ok" ok
  check_path "$target" "'$slash_dir/lmline_slash_link_ok'" ok
  check_path "$target" "$slash_dir/lmline_slash_link_bad" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_link_dir" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_missing" command-not-found
  check_path "$target" "'$slash_dir/lmline_slash_missing'" command-not-found
  check_path "$target" "\"$slash_dir/lmline_slash_missing\"" command-not-found
  # Dynamic, escaped, concatenated or otherwise opaque spellings fail closed
  # without expansion, even where a literal spelling would be available.
  check_path "$target" '$HOME/lmline_slash_exe' command-not-found
  check_path "$target" '${lmline_slash_command:=/no/such/exe}' command-not-found
  tilde_cand=$(printf '~%s' '/lmline_slash_exe')
  check_path "$target" "$tilde_cand" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_*" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_exe\$HOME" command-not-found
  check_path "$target" "\"$slash_dir/lmline_slash_exe\$HOME\"" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_exe\\x" command-not-found
  check_path "$target" "$slash_dir/'lmline_slash_exe'" command-not-found
  check_path "$target" "'$slash_dir/'lmline_slash_exe" command-not-found
  check_path "$target" "'$slash_dir/has space'" command-not-found
  check_path "$target" "\"$slash_dir/has space\"" command-not-found
  if [[ "$target" == bash ]]; then
    check_path "$target" '{/no/such,/also/missing}/lmline_slash_exe' command-not-found
  fi
  check_path "$target" '$lmline_slash_command' command-not-found
  check_path "$target" '"$lmline_slash_command"' command-not-found
  # Literal command names remain usable; their arguments stay data.
  check_path "$target" "'printf' '$slash_dir/lmline_slash_missing'" ok
  # Quoted arguments, comments and redirection operands stay opaque.
  check_path "$target" "printf '$slash_dir/lmline_slash_missing'" ok
  check_path "$target" "printf ok # $slash_dir/lmline_slash_missing" ok
  check_path "$target" "printf ok # ; $slash_dir/lmline_slash_missing" ok
  check_path "$target" "$slash_dir/lmline_slash_exe > /dev/null" ok
  check_path "$target" "> /dev/null $slash_dir/lmline_slash_exe" ok
  check_path "$target" "2>/dev/null $slash_dir/lmline_slash_exe" ok
  check_path "$target" "> 'unused output / path' $slash_dir/lmline_slash_exe" ok
  check_path "$target" "< 'unused input / path' $slash_dir/lmline_slash_exe" ok
  check_path "$target" "<> 'unused input / path' $slash_dir/lmline_slash_exe" ok
  check_path "$target" "< 'unused input / path' $slash_dir/lmline_slash_missing" command-not-found
  check_path "$target" ">\"unused output / path\" $slash_dir/lmline_slash_exe" ok
  check_path "$target" "> 'unused output / path' $slash_dir/lmline_slash_missing" command-not-found
  check_path "$target" "> /dev/null /no/such/lmline_missing_executable" command-not-found
  check_path "$target" "$slash_dir/lmline_slash_exe -- $slash_dir/lmline_slash_missing" ok
  # Wrappers carry the path command.
  check_path "$target" "command $slash_dir/lmline_slash_exe" ok
  check_path "$target" "command $slash_dir/lmline_slash_missing" command-not-found
  check_path "$target" "sudo $slash_dir/lmline_slash_missing" command-not-found
  # Direct PATH-prefix fast paths apply the same file check; PATH text is
  # irrelevant to slash resolution.
  check_path "$target" "PATH=/usr/bin:/bin $slash_dir/lmline_slash_exe" ok
  check_path "$target" "PATH=/nonexistent $slash_dir/lmline_slash_exe" ok
  check_path "$target" "PATH=/usr/bin:/bin $slash_dir/lmline_slash_missing" command-not-found
  check_path "$target" "PATH=/nonexistent $slash_dir/lmline_slash_missing" command-not-found
  check_path "$target" "PATH=/nonexistent '$slash_dir/lmline_slash_exe'" ok
  check_path "$target" "PATH=/nonexistent \"$slash_dir/lmline_slash_exe\"" ok
  check_path "$target" "PATH=/nonexistent '$slash_dir/lmline_slash_missing'" command-not-found
  check_path "$target" "PATH=/nonexistent $slash_dir/'lmline_slash_exe'" command-not-found
  if [[ "$target" == zsh ]]; then
    check_path "$target" "path=/nonexistent '$slash_dir/lmline_slash_exe'" ok
    check_path "$target" "path=/nonexistent $slash_dir/lmline_slash_missing" command-not-found
  fi
  # Relative slash paths after a possible directory change fail closed even
  # with an all-absolute inherited PATH; absolute paths stay independent.
  slash_orig_pwd=$PWD
  slash_orig_path=$PATH
  cd "$slash_dir" || fail "$target slash fixture cd"
  export PATH=/usr/bin:/bin
  check_path "$target" './lmline_slash_exe' ok
  check_path "$target" "'./lmline_slash_exe'" ok
  check_path "$target" '"./lmline_slash_exe"' ok
  check_path "$target" 'PATH=/nonexistent ./lmline_slash_exe' ok
  check_path "$target" "cd \"$slash_empty\"; ./lmline_slash_exe" command-not-found
  check_path "$target" "cd '$slash_empty'; './lmline_slash_exe'" command-not-found
  check_path "$target" "'cd' '$slash_empty'; \"./lmline_slash_exe\"" command-not-found
  check_path "$target" "command cd '$slash_empty'; ./lmline_slash_exe" command-not-found
  check_path "$target" "pushd '$slash_empty'; ./lmline_slash_exe" command-not-found
  check_path "$target" 'cd "$destination"; ./lmline_slash_exe' command-not-found
  check_path "$target" "printf 'cd $slash_empty'; ./lmline_slash_exe" ok
  check_path "$target" "printf ok > 'cd / output'; ./lmline_slash_exe" ok
  check_path "$target" "bash -c 'cd /; ./lmline_slash_exe'" command-not-found
  check_path "$target" "cd \"$slash_empty\"; $slash_dir/lmline_slash_exe" ok
  check_path "$target" "cd \"$slash_empty\"; \"$slash_dir/lmline_slash_exe\"" ok
  cd "$slash_orig_pwd" || fail "$target slash restore cd"
  export PATH="$slash_orig_path"
  # Non-execution: the probe stub would mark itself if it ever ran; static
  # validation uses metadata only.
  slash_marker=$path_tmp/$target-slash-executed
  slash_marker_ok=$path_tmp/$target-slash-executed-ok
  rm -f "$slash_marker" "$slash_marker_ok"
  check_path "$target" "touch \"$slash_marker\"" ok
  check_path "$target" "$slash_dir/lmline_slash_exe" ok
  check_path "$target" "$slash_dir/lmline_slash_missing; touch \"$slash_marker_ok\"" command-not-found
  [[ ! -e "$slash_marker" && ! -e "$slash_marker_ok" && ! -e "$slash_probe_marker" ]] || fail "$target slash validation executed candidate text or stub"
  ok "$target explicit command-path validation and non-execution"
done

ok "PATH-prefix availability"
