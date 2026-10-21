#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: privacy scanning fails closed before packaging or heavyweight publish steps.

# The privacy scan must fail closed: missing rg, scanner error, and match
# content all reject before the heavy test/install stages, so none of these
# paths run ./tests/run.sh and none can recurse into this file.
fake_bin=$(mktemp -d "${TMPDIR:-/tmp}/lmline-publish-fake.XXXXXX")
trap 'rm -rf "$fake_bin"' EXIT

# Missing rg: isolated PATH without rg fails with an actionable message.
no_rg_bin=$(mktemp -d "${TMPDIR:-/tmp}/lmline-publish-norg.XXXXXX")
for tool in bash dirname mktemp rm find grep; do
  tool_path=$(command -v "$tool" 2>/dev/null) || continue
  ln -s "$tool_path" "$no_rg_bin/$tool"
done
if PATH="$no_rg_bin" bash "$repo_dir/scripts/publish-check.sh" >"$fake_bin/missing.out" 2>"$fake_bin/missing.err"; then
  fail "publish-check without rg passed open"
fi
grep -q 'rg is required for the privacy scan' "$fake_bin/missing.err" || fail "publish-check missing rg message"
! grep -q '^publish-check: ok$' "$fake_bin/missing.out" || fail "publish-check without rg reported ok"
rm -rf "$no_rg_bin"

# Scanner error (rg exit 2) must fail, not read as clean no-match.
printf '#!/usr/bin/env bash\nexit 2\n' >"$fake_bin/rg"
chmod +x "$fake_bin/rg"
if PATH="$fake_bin:$PATH" bash "$repo_dir/scripts/publish-check.sh" >"$fake_bin/error.out" 2>"$fake_bin/error.err"; then
  fail "publish-check with failing scanner passed open"
fi
grep -q 'privacy scan failed' "$fake_bin/error.err" || fail "publish-check scanner error message"
! grep -q '^publish-check: ok$' "$fake_bin/error.out" || fail "publish-check with failing scanner reported ok"

# Match content (rg exit 0) must fail as secret-looking content.
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/rg"
chmod +x "$fake_bin/rg"
if PATH="$fake_bin:$PATH" bash "$repo_dir/scripts/publish-check.sh" >"$fake_bin/match.out" 2>"$fake_bin/match.err"; then
  fail "publish-check with matching scan passed open"
fi
grep -q 'the privacy scan failed' "$fake_bin/match.err" || fail "publish-check match message"

ok "publish privacy scan fails closed"
