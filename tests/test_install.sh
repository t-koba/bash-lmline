#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: relative install overrides still produce a usable, stable CLI link.

install_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-install-test.XXXXXX")
trap 'rm -rf "$install_tmp"' EXIT
mkdir -p "$install_tmp/work" "$install_tmp/home"

(
  cd "$install_tmp/work"
  CDPATH=. HOME="$install_tmp/home" LMLINE_CONFIG_DIR=config LMLINE_BIN_DIR=bin \
    bash "$repo_dir/install.sh" >"$install_tmp/install.out"
)

expected_target=$install_tmp/work/config/lmline
[[ $(readlink "$install_tmp/work/bin/lmline") == "$expected_target" ]] || fail "relative install link target"
[[ -x "$install_tmp/work/bin/lmline" ]] || fail "relative install link is executable"

if ! (
  cd "$install_tmp"
  HOME="$install_tmp/home" PATH="$install_tmp/work/bin:$PATH" lmline --help >"$install_tmp/help.out"
); then
  fail "installed CLI --help through relative overrides"
fi
grep -q '^usage: lmline ' "$install_tmp/help.out" || fail "installed CLI help output"

ok "relative install overrides create a usable CLI"
