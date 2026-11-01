#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_dir"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/lmline-publish.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

if [[ -e request.md ]]; then
  printf 'publish-check: request.md must not be present in the publish tree\n' >&2
  exit 1
fi

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  printf 'publish-check: bash 4.2 or newer is required; current version is %s\n' "$BASH_VERSION" >&2
  exit 1
fi

# Shipped Bash, Node, and Zsh syntax is owned by tests/test_syntax.sh, which
# the suite below runs.

if ! bash "$repo_dir/scripts/privacy-scan.sh" >/dev/null; then
  printf 'publish-check: the privacy scan failed\n' >&2
  exit 1
fi

if [[ ! -f .gitattributes ]] || ! grep -q '^\.DS_Store[[:space:]].*export-ignore' .gitattributes; then
  printf 'publish-check: .gitattributes must export-ignore .DS_Store\n' >&2
  exit 1
fi

if ! bash scripts/check-commit-subjects.sh; then
  printf 'publish-check: a commit subject does not follow the rule\n' >&2
  exit 1
fi

test_log=$work_dir/tests.log
if ! env -u LMLINE_BASE_URL -u LMLINE_MODEL -u LMLINE_API_KEY_FILE ./tests/run.sh >"$test_log" 2>&1; then
  cat "$test_log" >&2
  exit 1
fi
cat "$test_log"

tmp_config=$work_dir/config
tmp_bin=$work_dir/bin
LMLINE_CONFIG_DIR="$tmp_config" LMLINE_BIN_DIR="$tmp_bin" ./install.sh >/dev/null
LMLINE_CONFIG_DIR="$tmp_config" "$tmp_bin/lmline" doctor >/dev/null

for required in README.md SECURITY.md LICENSE install.sh lmline/engine lmline/lmline lmline/copilot-client.js lmline/chatgpt-client.js; do
  [[ -r "$required" ]] || {
    printf 'publish-check: missing required file: %s\n' "$required" >&2
    exit 1
  }
done

printf 'publish-check: ok\n'
