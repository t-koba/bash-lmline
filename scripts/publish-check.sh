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

bash -n \
  install.sh \
  lmline/engine \
  lmline/lmline \
  lmline/init.bash \
  lmline/actions.bash \
  lmline/context.bash \
  lmline/config.bash \
  lmline/policy.bash \
  lmline/http.bash \
  lmline/profiles.bash \
  lmline/chat.bash \
  tests/*.sh

if command -v zsh >/dev/null 2>&1; then
  zsh -n lmline/init.zsh
fi

if command -v rg >/dev/null 2>&1; then
  if rg -n '(/Users/|Mac-Air|local/llm-completion|BEGIN .*PRIVATE|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})' \
    -uu --glob '!.git/**' --glob '!PUBLISHING.md' --glob '!scripts/publish-check.sh' --glob '!request.md' .; then
    printf 'publish-check: local path or secret-looking value found\n' >&2
    exit 1
  fi
fi

if find . -path './.git' -prune -o -maxdepth 3 -type f \( -name '.DS_Store' -o -name '*secret*' -o -name '*.key' -o -name '*.pem' -o -name '.env*' -o -name '*token*' \) -print | grep .; then
  printf 'publish-check: secret-like file name found\n' >&2
  exit 1
fi

if [[ ! -f .gitattributes ]] || ! grep -q '^\.DS_Store[[:space:]].*export-ignore' .gitattributes; then
  printf 'publish-check: .gitattributes must export-ignore .DS_Store\n' >&2
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

for required in README.md SECURITY.md LICENSE install.sh lmline/engine lmline/lmline; do
  [[ -r "$required" ]] || {
    printf 'publish-check: missing required file: %s\n' "$required" >&2
    exit 1
  }
done

printf 'publish-check: ok\n'
