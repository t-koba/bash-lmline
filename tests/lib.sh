#!/usr/bin/env bash
# Shared test harness for lmline test files. Source from each test_*.sh.
set -euo pipefail

# Locale-stable assertions regardless of the developer machine locale.
export LC_ALL=C

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$*"
}

# Extracts candidate text from engine "lmline-candidate:" protocol lines.
candidates_of() {
  awk '/^lmline-candidate: /{ s = $0; sub(/^lmline-candidate: /, "", s); for (i = 0; i < 3; i++) { t = index(s, "\t"); s = substr(s, t + 1) } print s }'
}
