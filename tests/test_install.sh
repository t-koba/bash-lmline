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
expected_config_dir=$(CDPATH='' cd -- "$install_tmp/work/config" && pwd -P)
actual_config_dir=$(CDPATH='' cd -- "${actual_target%/*}" && pwd -P)
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

# The installer's temporary config file must use a safe operand when TMPDIR
# is a dash-leading relative directory; it must not silently fall back to /tmp
# or rewrite the caller's setting.
fake_bin="$install_tmp/fake-bin"
mkdir -m 700 "$fake_bin" "$install_tmp/work/-tmp"
: >"$install_tmp/install-mktemp.log"
real_mktemp=$(command -v mktemp)
cat >"$fake_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
for last do :; done
printf '%s\n' "$last" >>"$LMLINE_MKTEMP_LOG"
exec "$LMLINE_REAL_MKTEMP" "$@"
EOF
chmod +x "$fake_bin/mktemp"
# Give the installer a clipboard provider so it actually creates a config
# entry through mktemp; detection is otherwise environment dependent.
printf '#!/bin/sh\nexit 0\n' >"$fake_bin/xclip"
chmod +x "$fake_bin/xclip"
(
  cd "$install_tmp/work" || exit 1
  PATH="$fake_bin:$PATH" TMPDIR=-tmp     LMLINE_MKTEMP_LOG="$install_tmp/install-mktemp.log"     LMLINE_REAL_MKTEMP="$real_mktemp"     HOME="$install_tmp/home" LMLINE_CONFIG_DIR=dash-config LMLINE_BIN_DIR=dash-bin     bash "project dir/install.sh" >"$install_tmp/dash-install.out" 2>&1
) || {
  cat "$install_tmp/dash-install.out" >&2
  fail "installer failed with a dash-leading TMPDIR"
}
grep -q '^\./-tmp/lmline-cfg' "$install_tmp/install-mktemp.log" ||
  fail "installer did not use a safe dash-leading TMPDIR operand"
ok "installer normalizes a dash-leading TMPDIR"
