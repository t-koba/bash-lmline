#!/usr/bin/env bash
# Test runner: executes every tests/test_*.sh in order, reports all failures
# instead of stopping at the first failing file, and exits non-zero if any
# file failed. Individual files fail fast internally via lib.sh fail().
set -u

tests_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
failed=()

for test_file in "$tests_dir"/test_*.sh; do
  name=$(basename "$test_file")
  if ! bash "$test_file"; then
    printf 'not ok - %s\n' "$name" >&2
    failed+=("$name")
  fi
done

if ((${#failed[@]} > 0)); then
  printf 'FAILED files: %s\n' "${failed[*]}" >&2
  exit 1
fi
printf 'all test files passed\n'
