#!/usr/bin/env bash
# Test runner: executes every tests/test_*.sh in order, reports all failures
# instead of stopping at the first failing file, and exits non-zero if any
# file failed. Individual files fail fast internally via lib.sh fail().
set -u

tests_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
failed=()
# Bash SECONDS keeps per-file timings portable across the Linux and macOS runners.
suite_started=$SECONDS

for test_file in "$tests_dir"/test_*.sh; do
  name=$(basename "$test_file")
  test_started=$SECONDS
  if ! bash "$test_file"; then
    printf 'not ok - %s\n' "$name" >&2
    failed+=("$name")
  fi
  printf 'duration - %s: %ss\n' "$name" "$((SECONDS - test_started))"
done

suite_elapsed=$((SECONDS - suite_started))
if ((${#failed[@]} > 0)); then
  printf 'FAILED files: %s\n' "${failed[*]}" >&2
  printf 'test suite duration: %ss\n' "$suite_elapsed"
  exit 1
fi
printf 'all test files passed (%ss)\n' "$suite_elapsed"
