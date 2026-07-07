#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# init.zsh is excluded: shellcheck does not support zsh; zsh -n covers it in
# test_syntax.sh. LMLINE_REQUIRE_SHELLCHECK=1 (set in CI) turns the local
# skip into a failure so CI cannot silently lose lint coverage.
if ! command -v shellcheck >/dev/null 2>&1; then
  [[ "${LMLINE_REQUIRE_SHELLCHECK:-0}" == 1 ]] && fail "shellcheck required but not installed"
  ok "shellcheck (skipped: not installed)"
  exit 0
fi

shellcheck -s bash \
  "$repo_dir/lmline/lmline" \
  "$repo_dir/lmline/engine" \
  "$repo_dir"/lmline/*.bash \
  "$repo_dir/install.sh" \
  "$repo_dir"/tests/*.sh \
  || fail "shellcheck findings"
ok "shellcheck"
