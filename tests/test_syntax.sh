#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

for file in "$repo_dir"/lmline/*.bash "$repo_dir"/lmline/completions/lmline.bash "$repo_dir"/lmline/engine "$repo_dir"/lmline/lmline "$repo_dir"/install.sh; do
  bash -n "$file" || fail "bash -n $file"
done
ok "bash syntax"

if command -v node >/dev/null 2>&1; then
  node --check "$repo_dir/lmline/copilot-client.js" || fail "node syntax copilot-client.js"
  node --check "$repo_dir/tests/fake_copilot_ls.js" || fail "node syntax fake_copilot_ls.js"
  ok "node syntax"
fi


if command -v zsh >/dev/null 2>&1; then
  zsh -n "$repo_dir/lmline/init.zsh" || fail "zsh -n init.zsh"
  zsh -n "$repo_dir/lmline/completions/_lmline" || fail "zsh -n completions/_lmline"
  ok "zsh syntax"
fi
