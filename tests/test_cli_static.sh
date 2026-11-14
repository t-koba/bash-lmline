#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: only the recognized static routes may bypass configuration loading.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-static-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp"/{empty,valid,invalid,missing,bin,project}
: >"$tmp/empty/settings.bash"
# A substantial valid config with project loading enabled makes skipped work
# observable without timing assertions or invoking any provider.
awk 'BEGIN { for (i = 0; i < 4096; i++) print "# synthetic settings comment padding padding padding padding pad" }' >"$tmp/valid/settings.bash"
printf "export LMLINE_PS0='configured sentinel'\nexport LMLINE_PROJECT_CONFIG='1'\n" >>"$tmp/valid/settings.bash"
cp "$tmp/valid/settings.bash" "$tmp/invalid/settings.bash"
printf 'if (\nexport LMLINE_PS0="$(touch %s)"\n' "$tmp/executed" >>"$tmp/invalid/settings.bash"
cat >"$tmp/bin/git" <<'SH'
#!/bin/sh
printf 'called\n' >>"$git_marker"
exit 1
SH
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH" git_marker="$tmp/git-called"
# Ignore any real project settings in the checkout or parent directory.
cd "$tmp/project"
export LMLINE_PROJECT_CONFIG=0

while IFS= read -r route; do
  read -r -a args <<<"$route"
  LMLINE_CONFIG_DIR="$tmp/empty" "$repo_dir/lmline/lmline" "${args[@]}" >"$tmp/expected" 2>"$tmp/expected.err" || fail "static baseline: $route"
  for state in valid invalid missing; do
    LMLINE_CONFIG_DIR="$tmp/$state" "$repo_dir/lmline/lmline" "${args[@]}" >"$tmp/actual" 2>"$tmp/actual.err" || fail "static $state: $route"
    cmp -s "$tmp/expected" "$tmp/actual" || fail "static stdout changed ($state): $route"
    cmp -s "$tmp/expected.err" "$tmp/actual.err" || fail "static stderr changed ($state): $route"
    [[ ! -e "$git_marker" ]] || fail "static route loaded config: $route"
  done
done <<'ROUTES'
-h
--help
help
help sandbox run
config -h
config --help
sandbox setup -h
sandbox setup --help
config describe -h
config describe --help
endpoint add -h
endpoint add --help
model refresh -h
model refresh --help
history show -h
history show --help
debug trace -h
debug trace --help
payload generate -h
payload generate --help
config defaults
config defaults -h
config defaults --help
ROUTES

# Basic config, profile and full-setup branches must still load settings;
# help forms not in the static allowlist must not be swept in by a wildcard.
for route in 'config get' 'config get --help' 'endpoint list --help' 'context --help'; do
  rm -f "$git_marker"
  read -r -a args <<<"$route"
  LMLINE_CONFIG_DIR="$tmp/valid" "$repo_dir/lmline/lmline" "${args[@]}" >"$tmp/actual" || fail "dynamic route: $route"
  [[ -e "$git_marker" ]] || fail "dynamic route skipped config: $route"
done
for state in valid invalid; do
  LMLINE_CONFIG_DIR="$tmp/$state" "$repo_dir/lmline/lmline" config describe LMLINE_PS0 >"$tmp/actual"
  grep -q '^value=configured sentinel$' "$tmp/actual" || fail "dynamic config parsing ($state)"
done
[[ ! -e "$tmp/executed" ]] || fail "malformed config was executed"
# Missing settings and malformed lines are ignored by the existing loader.
# A config-dependent file lookup must still reject a missing configured file.
printf "export LMLINE_CLIPBOARD_PROVIDERS_FILE='%s'\n" "$tmp/no-providers.tsv" >>"$tmp/valid/settings.bash"
if LMLINE_CONFIG_DIR="$tmp/valid" "$repo_dir/lmline/lmline" complete clipboard-providers >"$tmp/actual" 2>"$tmp/actual.err"; then
  fail "dynamic completion skipped configured-file validation"
fi
grep -q 'file is not readable' "$tmp/actual.err" || fail "missing configured-file diagnostic"
ok "static CLI config independence and dynamic config loading"
