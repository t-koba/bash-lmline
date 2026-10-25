#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: caller functions must be names-only data, never validation helpers.
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

boundary_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-boundary.XXXXXX")
trap 'status=$?; if [[ -e "$boundary_tmp/body-ran" ]]; then printf "ERROR: caller body ran; stop validation\n" >&2; else printf "boundary marker absent (status %s)\n" "$status" >&2; fi; rm -rf "$boundary_tmp"' EXIT
export boundary_tmp
(
# Install markers only after the protected launch and syntax probes exist.
# shellcheck disable=SC2329
read() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
builtin() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
bash() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
declare() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
compgen() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
lmline_boundary_export() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
lmline_boundary_local() { : >"$boundary_tmp/body-ran"; }
export -f read builtin bash declare compgen lmline_boundary_export

# Fail immediately on any body execution; never retry such a path.
names=$(__lmline_collect_exported_functions)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
for name in read builtin bash declare compgen lmline_boundary_export; do
  [[ $'\n'"$names"$'\n' == *$'\n'"$name"$'\n'* ]] || exit 1
done
[[ "$names" != *body-ran* && "$names" != *lmline_boundary_local* ]] || exit 1
all_names=$(__lmline_collect_shell_functions)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ $'\n'"$all_names"$'\n' == *$'\n'lmline_boundary_local$'\n'* ]] || exit 1

actual=$(__lmline_candidate_rejection_reason 'lmline_boundary_local; read; builtin; bash -c "lmline_boundary_export"' rewrite bash)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ "$actual" == ok ]] || exit 1
actual=$(__lmline_candidate_rejection_reason "unset -f bash; bash -c 'lmline_boundary_local'" rewrite bash)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ "$actual" == command-not-found ]] || exit 1
actual=$(__lmline_candidate_rejection_reason "unset -f bash; unset -f lmline_boundary_export; time X=1 bash -c 'lmline_boundary_export'" rewrite bash)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ "$actual" == command-not-found ]] || exit 1
actual=$(__lmline_candidate_rejection_reason "unset -f read; command read" rewrite bash)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ "$actual" == ok ]] || exit 1

# The clean boundary must retain ordinary exported lookup state. This is a
# names-only check: the candidate and its symlink target are never executed.
path_dir=$boundary_tmp/path-only
mkdir "$path_dir" || exit 1
true_path=$(type -P true) || exit 1
[[ -x $true_path ]] || exit 1
ln -s "$true_path" "$path_dir/lmline_boundary_path_probe" || exit 1
PATH=$path_dir:$PATH
export PATH
actual=$(__lmline_candidate_rejection_reason 'lmline_boundary_path_probe' rewrite bash)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ "$actual" == ok ]] || exit 1

# One clean batch, with the same filter used by the in-process Copilot bridge.
actual=$(__lmline_validation_run copilot bash rewrite <<'BATCH'
a	lmline_boundary_export
b	unset -f bash; bash -c 'lmline_boundary_local'
c	unset -f lmline_boundary_export; X=1 lmline_boundary_export
BATCH
)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
[[ "$actual" == *$'\tlmline_boundary_export' && "$actual" != *copilot:b* && "$actual" != *copilot:c* ]] || exit 1

# An unremovable helper shadow cannot be safely inspected: fail closed, even
# when the caller invokes the validator in an errexit-suppressed condition.
if rejected=$(readonly -f builtin; __lmline_candidate_rejection_reason 'printf safe' rewrite bash); then
  exit 1
fi
[[ ! -e "$boundary_tmp/body-ran" && -z "$rejected" ]] || exit 1

# Special-builtin precedence must bootstrap even with both dispatch helpers
# shadowed. Keep these two bindings outside the removal-policy fixtures above,
# where a real caller function named unset would change candidate semantics.
# shellcheck disable=SC2329
command() { : >"$boundary_tmp/body-ran"; }
# shellcheck disable=SC2329
unset() { : >"$boundary_tmp/body-ran"; }
export -f command unset
for collector in __lmline_collect_shell_functions __lmline_collect_exported_functions; do
  names=$("$collector")
  [[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
  for name in command unset; do
    [[ $'\n'"$names"$'\n' == *$'\n'"$name"$'\n'* ]] || exit 1
  done
done
actual=$(__lmline_candidate_rejection_reason 'printf safe' rewrite bash)
[[ ! -e "$boundary_tmp/body-ran" && "$actual" == ok ]] || exit 1

# Executable entry points must isolate before their first helper, too. These
# are real lmline programs, not candidate/stub executable dispatch.
# readlink is needed only by the pre-isolation link resolver. A caller
# function with that name must be bypassed, not removed from caller metadata.
# shellcheck disable=SC2329
readlink() { : >"$boundary_tmp/body-ran"; }
export -f readlink
ln -s "$repo_dir/lmline/lmline" "$boundary_tmp/lmline-link"
ln -s lmline-link "$boundary_tmp/lmline-relative"
ln -s lmline-relative "$boundary_tmp/-lmline-link"
for entry in "$repo_dir/lmline/lmline" "$boundary_tmp/lmline-link" "$boundary_tmp/lmline-relative"; do
  "$entry" --help >"$boundary_tmp/help"
  [[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
done
# Bash can receive a dash-leading script name without a ./ prefix. The
# resolver must protect the readlink operand without GNU-only options.
(cd "$boundary_tmp" && "$BASH" -- -lmline-link --help >"$boundary_tmp/dash-help") || exit 1
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
: >"$boundary_tmp/empty"
"$repo_dir/lmline/engine" --mode rewrite --shell bash --line-file "$boundary_tmp/empty" --context-file "$boundary_tmp/empty" >"$boundary_tmp/result"
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
)
[[ ! -e "$boundary_tmp/body-ran" ]] || exit 1
ok "validation boundary does not dispatch exported helper names"

# A policy helper is not a real fallback after its caller binding is removed.
# Zsh also must not borrow Bash policy helpers for target-shell availability.
for target in bash zsh; do
  if [[ $target == zsh ]] && ! command -v zsh >/dev/null 2>&1; then continue; fi
  builtin type -P -- __lmline_candidate_truncated >/dev/null 2>&1 \
    && fail "helper-removal fixture unexpectedly has a PATH fallback"
  actual=$(__lmline_candidate_rejection_reason 'unset -f __lmline_candidate_truncated; __lmline_candidate_truncated' rewrite "$target")
  [[ $actual == command-not-found ]] || fail "$target helper removal: $actual"
  actual=$(__lmline_candidate_rejection_reason 'unset -f read; read' rewrite "$target")
  [[ $actual == ok ]] || fail "$target removed function lost builtin fallback: $actual"
done
ok "unmatched words require target-shell builtin/PATH fallbacks"

# Sourcing the entry point retains readonly attributes, unlike an export.
# The bootstrap must fail closed rather than dispatch this unremovable shadow.
if "$BASH" -c '
  command() { : >"$boundary_tmp/body-ran"; }
  readonly -f command
  source "$1" --help
' _ "$repo_dir/lmline/lmline" >"$boundary_tmp/readonly-out" 2>"$boundary_tmp/readonly-error"; then
  fail "CLI bootstrap accepted a readonly command shadow"
fi
[[ ! -e "$boundary_tmp/body-ran" && ! -s "$boundary_tmp/readonly-out" ]] \
  || fail "readonly CLI bootstrap dispatched a body"
ok "CLI bootstrap fails closed on an unremovable helper shadow"

# The two new runtime files must also ship in an installed tree.
LMLINE_CONFIG_DIR="$boundary_tmp/install" LMLINE_BIN_DIR="$boundary_tmp/bin" \
  "$BASH" "$repo_dir/install.sh" >"$boundary_tmp/install.log"
"$boundary_tmp/bin/lmline" --help >"$boundary_tmp/installed-help"
ln -s ../install/lmline "$boundary_tmp/bin/lmline-relative"
"$boundary_tmp/bin/lmline-relative" --help >"$boundary_tmp/installed-relative-help"
actual=$(LMLINE_CONFIG_DIR="$boundary_tmp/install" "$BASH" -c '
  source "$1/policy.bash"
  __lmline_candidate_rejection_reason "printf installed" rewrite bash
' _ "$boundary_tmp/install")
[[ "$actual" == ok ]] || fail "installed validation boundary: $actual"
ok "installation includes the clean validator and names-only launcher"
