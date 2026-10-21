#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: pinned ShellCheck covers every supported Bash source/test input with correct source resolution.

# With no arguments runs the full ShellCheck batch (pinned via
# scripts/install-shellcheck.sh when LMLINE_REQUIRE_SHELLCHECK=1, otherwise
# an installed shellcheck or skip). With exactly --provision-only, provisions
# the pinned platform asset via scripts/install-shellcheck.sh (which checks
# its SHA-256 and version), verifies the installed binary runs, then exits
# before the lint. Any other arguments fail closed.
provision_only=0
if (($# > 1)); then
  printf 'usage: %s [--provision-only]\n' "$0" >&2
  exit 2
elif (($# == 1)); then
  if [[ "$1" == "--provision-only" ]]; then
    provision_only=1
  else
    printf 'usage: %s [--provision-only]\n' "$0" >&2
    exit 2
  fi
fi

# Resolve ShellCheck source hints consistently, including direct invocations from elsewhere.
cd -- "$repo_dir" || fail "could not enter repository root for ShellCheck"

if ((provision_only)); then
  pinned_bin_dir=$(sh "$repo_dir/scripts/install-shellcheck.sh") || fail "pinned ShellCheck setup failed"
  trap 'rm -rf "$pinned_bin_dir"' EXIT
  PATH="$pinned_bin_dir:$PATH"
  command -v shellcheck >/dev/null 2>&1 || fail "pinned shellcheck not found"
  shellcheck --version >/dev/null 2>&1 || fail "pinned shellcheck version check failed"
  ok "shellcheck provisioning"
  exit 0
fi

# init.zsh is excluded: shellcheck does not support zsh; zsh -n covers it in
# test_syntax.sh. LMLINE_REQUIRE_SHELLCHECK=1 (set in CI and mizu_verify)
# always uses the manifest pin via scripts/install-shellcheck.sh (which
# prefers /pinned and otherwise downloads the same URL); otherwise an
# installed shellcheck is used, or the test skips when none is installed.
if [[ "${LMLINE_REQUIRE_SHELLCHECK:-0}" == 1 ]]; then
  pinned_bin_dir=$(sh "$repo_dir/scripts/install-shellcheck.sh") || fail "pinned ShellCheck setup failed"
  trap 'rm -rf "$pinned_bin_dir"' EXIT
  PATH="$pinned_bin_dir:$PATH"
  command -v shellcheck >/dev/null 2>&1 || fail "pinned shellcheck not found"
else
  if ! command -v shellcheck >/dev/null 2>&1; then
    ok "shellcheck (skipped: not installed)"
    exit 0
  fi
fi

shellcheck -s bash \
  "$repo_dir/lmline/lmline" \
  "$repo_dir/lmline/engine" \
  "$repo_dir"/lmline/*.bash \
  "$repo_dir/lmline/completions/lmline.bash" \
  "$repo_dir/install.sh" \
  "$repo_dir/scripts/install-shellcheck.sh" \
  "$repo_dir/scripts/check-commit-subjects.sh" \
  "$repo_dir/scripts/privacy-scan.sh" \
  "$repo_dir/scripts/publish-check.sh" \
  "$repo_dir"/tests/*.sh \
  || fail "shellcheck findings"
ok "shellcheck"
