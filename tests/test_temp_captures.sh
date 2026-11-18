#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: test captures stay in per-run temporary directories rather than fixed /tmp paths.

capture_pattern='/tmp/lmline-[[:alnum:]_.-]*\.(out|err)'

fixed_captures() {
  grep -rEn "$capture_pattern" "$1/tests" 2>/dev/null || true
}

work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-captures.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tests"

# Per-run captures and ordinary /tmp test data are both allowed.
cat >"$work/tests/test_fixture.sh" <<'FIXTURE'
__lmline_widget >"$dir/capture.out" 2>"$dir/capture.err"
marker="/tmp/lmline-model-id-executed-$$"
engine='/tmp/lmline-unapproved-engine'
FIXTURE
[[ -z "$(fixed_captures "$work")" ]] || fail "per-run captures and literal paths were reported"

# A fixed capture is reported with its file and line.
fixed_root='/tmp'
printf 'run >%s/lmline-fixture.out 2>%s/lmline-fixture.err\n' \
  "$fixed_root" "$fixed_root" >>"$work/tests/test_fixture.sh"
reported=$(fixed_captures "$work")
[[ -n "$reported" ]] || fail "a fixed capture path was not reported"
grep -q 'test_fixture.sh:4:' <<<"$reported" \
  || fail "the report does not identify the offending line: $reported"

# A dot inside the basename is just as fixed as a flat name.
printf 'run >%s/lmline-dotted.case.out 2>%s/lmline-dotted.case.err\n' \
  "$fixed_root" "$fixed_root" >>"$work/tests/test_fixture.sh"
reported=$(fixed_captures "$work")
grep -q 'test_fixture.sh:5:' <<<"$reported" \
  || fail "a dotted fixed capture path was not reported: $reported"

# The repository itself keeps the convention.
reported=$(fixed_captures "$repo_dir")
[[ -z "$reported" ]] || fail "fixed capture paths remain in the test suite: $reported"

ok "test captures use per-run temporary directories"
