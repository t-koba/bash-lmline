#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
printf 'list json files\n' >"$tmp/line"
printf '## available_commands\nfind\nsort\n' >"$tmp/context"
printf '\n' >"$tmp/empty-line"

empty_rewrite_out=$("$repo_dir/lmline/engine" --mode rewrite --shell bash --cwd "$repo_dir" --point 0 --line-file "$tmp/empty-line" --context-file "$tmp/context" --n 1)
[[ -z "$empty_rewrite_out" ]] || fail "empty rewrite engine guard"

if LMLINE_CONFIG_DIR="$tmp/smoke-config" LMLINE_BASE_URL="${LMLINE_BASE_URL:-http://127.0.0.1:1234/v1}" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$tmp/line" --context-file "$tmp/context" --n 1 >/tmp/lmline-engine-smoke.out 2>/tmp/lmline-engine-smoke.err; then
  if [[ -s /tmp/lmline-engine-smoke.out ]]; then
    ok "engine smoke"
  else
    fail "engine returned no candidates"
  fi
else
  printf 'skip - engine smoke (OpenAI-compatible local server unavailable or model not loaded)\n'
  sed -n '1,3p' /tmp/lmline-engine-smoke.err >&2 || true
fi

