#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for file in "$repo_dir"/lmline/*.bash "$repo_dir"/lmline/engine "$repo_dir"/lmline/lmline "$repo_dir"/install.sh; do
  bash -n "$file" || fail "bash -n $file"
done
ok "bash syntax"


if command -v zsh >/dev/null 2>&1; then
  zsh -n "$repo_dir/lmline/init.zsh" || fail "zsh -n init.zsh"
  ok "zsh syntax"
fi
