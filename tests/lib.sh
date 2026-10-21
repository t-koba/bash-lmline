#!/usr/bin/env bash
# Shared test harness for lmline test files. Source from each test_*.sh.
set -euo pipefail

# The harness is strict about its own commands, but the shells it starts to
# imitate a user's shell must not inherit that strictness. Bash hands the
# options of a shell to the shells it starts through SHELLOPTS when that
# variable is in the environment, and a shell that exits on the first failing
# command cannot show what the product does with one. Un-exporting the
# variable leaves the harness strict and the started shells plain.
export -n SHELLOPTS 2>/dev/null || true

# Locale-stable assertions regardless of the developer machine locale.
export LC_ALL=C

# Tests count engine HTTP calls; disable the response cache (default 600s)
# unless a test explicitly re-enables it.
export LMLINE_CACHE_TTL=0

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
