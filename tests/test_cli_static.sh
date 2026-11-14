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
printf "export LMLINE_CLIPBOARD_PROVIDERS_FILE='%s'\n" "$tmp/providers.tsv" >>"$tmp/valid/settings.bash"
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

# Fixed candidates (including empty catalogs) neither read settings nor resolve
# the configured, currently missing clipboard-provider file.
while IFS='|' read -r key values; do
  : >"$tmp/expected"
  if [[ -n "$values" ]]; then
    read -r -a candidates <<<"$values"
    printf '%s\n' "${candidates[@]}" >"$tmp/expected"
  fi
  for state in empty valid invalid missing; do
    LMLINE_CONFIG_DIR="$tmp/$state" "$repo_dir/lmline/lmline" complete setting-values "$key" >"$tmp/actual" 2>"$tmp/actual.err" || fail "fixed completion ($state): $key"
    cmp -s "$tmp/expected" "$tmp/actual" || fail "fixed candidates changed ($state): $key"
    [[ ! -s "$tmp/actual.err" ]] || fail "fixed completion stderr ($state): $key"
    [[ ! -e "$git_marker" ]] || fail "fixed completion loaded config: $key"
  done
done <<'VALUES'
LMLINE_API_FORMAT|chat responses messages
LMLINE_EXEC_BACKEND|auto local microsandbox off
LMLINE_TOOL_MODE|auto openai text none
LMLINE_RISK_PIPED_SHELL_LEVEL|low medium high
LMLINE_ASYNC|0 1
LMLINE_PS0|
UNKNOWN_SETTING|
VALUES

# Basic config, profile and full-setup branches must still load settings;
# help forms not in the static allowlist must not be swept in by a wildcard.
for route in 'config get' 'config get --help' 'endpoint list --help' 'context --help' 'complete clipboard-providers --help'; do
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
# Both provider-dependent catalogs must use configured data without running it,
# and retain the configured-file validation when that file disappears.
printf 'configured-copy\tprintf should-not-run\n' >"$tmp/providers.tsv"
printf 'auto\nconfigured-copy\n' >"$tmp/expected"
for route in 'complete setting-values LMLINE_CLIPBOARD_PROVIDER' 'complete clipboard-providers'; do
  read -r -a args <<<"$route"
  rm -f "$git_marker"
  LMLINE_CONFIG_DIR="$tmp/valid" "$repo_dir/lmline/lmline" "${args[@]}" >"$tmp/actual" 2>"$tmp/actual.err" || fail "provider completion: $route"
  cmp -s "$tmp/expected" "$tmp/actual" || fail "configured provider candidates: $route"
  [[ ! -s "$tmp/actual.err" ]] || fail "provider completion stderr: $route"
  [[ -e "$git_marker" ]] || fail "provider completion skipped config: $route"
done
rm "$tmp/providers.tsv"
for route in 'complete setting-values LMLINE_CLIPBOARD_PROVIDER' 'complete clipboard-providers'; do
  read -r -a args <<<"$route"
  if LMLINE_CONFIG_DIR="$tmp/valid" "$repo_dir/lmline/lmline" "${args[@]}" >"$tmp/actual" 2>"$tmp/actual.err"; then
    fail "provider completion skipped configured-file validation: $route"
  fi
  grep -q 'file is not readable' "$tmp/actual.err" || fail "missing configured-file diagnostic: $route"
done
ok "static CLI config independence and dynamic config loading"
