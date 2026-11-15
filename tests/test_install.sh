#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: a relative installer path and relative overrides stay usable under CDPATH.

install_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-install-test.XXXXXX")
trap 'rm -rf "$install_tmp"' EXIT
mkdir -p "$install_tmp/work" "$install_tmp/home"
ln -s "$repo_dir" "$install_tmp/work/project dir"

(
  cd "$install_tmp/work"
  CDPATH=. HOME="$install_tmp/home" LMLINE_CONFIG_DIR=config LMLINE_BIN_DIR=bin \
    bash "project dir/install.sh" >"$install_tmp/install.out"
)

actual_target=$(readlink "$install_tmp/work/bin/lmline")
[[ "$actual_target" == /* ]] || fail "relative install link is not absolute"
expected_config_dir=$(CDPATH= cd -- "$install_tmp/work/config" && pwd -P)
actual_config_dir=$(CDPATH= cd -- "${actual_target%/*}" && pwd -P)
[[ "${actual_target##*/}" == lmline && "$actual_config_dir" == "$expected_config_dir" ]] ||
  fail "relative install link does not resolve to the configured CLI"
[[ -x "$install_tmp/work/bin/lmline" ]] || fail "relative install link is executable"

if ! (
  cd "$install_tmp"
  HOME="$install_tmp/home" PATH="$install_tmp/work/bin:$PATH" lmline --help >"$install_tmp/help.out"
); then
  fail "installed CLI --help through relative overrides"
fi
grep -q '^usage: lmline ' "$install_tmp/help.out" || fail "installed CLI help output"

ok "relative installer and overrides create a usable CLI"
