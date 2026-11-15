#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

runner_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-runner-test.XXXXXX")
trap 'rm -rf "$runner_tmp"' EXIT
mkdir -p "$runner_tmp/tests" "$runner_tmp/bin"
cp "$repo_dir/tests/run.sh" "$runner_tmp/tests/run.sh"
cat > "$runner_tmp/tests/test_stub.sh" <<'STUB'
printf 'stub CDPATH=<%s>\n' "${CDPATH-unset}"
STUB
cat > "$runner_tmp/bin/bash" <<'BASH_SHIM'
#!/bin/sh
if [ ! -f "$1" ]; then
  printf 'missing test file: %s\n' "$1" >&2
  exit 99
fi
exec /bin/bash "$@"
BASH_SHIM
chmod +x "$runner_tmp/bin/bash"

if ! (
  cd "$runner_tmp"
  CDPATH=. PATH="$runner_tmp/bin:$PATH" /bin/bash tests/run.sh
) >"$runner_tmp/output" 2>&1; then
  cat "$runner_tmp/output" >&2
  fail "relative runner invocation with exported CDPATH"
fi
grep -Fxq 'start - test_stub.sh' "$runner_tmp/output" || fail "runner discovers stub test"
grep -Fxq 'stub CDPATH=<.>' "$runner_tmp/output" || fail "child retains CDPATH"
grep -q '^all test files passed ' "$runner_tmp/output" || fail "runner reports success"

ok "relative test runner discovery preserves exported CDPATH"
