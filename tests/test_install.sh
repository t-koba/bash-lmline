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

# Printed setup commands must stay pasteable when config_dir contains shell
# metacharacters: a double-quoted "$edition" would expand when pasted. Parse
# only the quoted path words from the output; never run the printed commands
# (two of them start interactive shells).
dollar_config="$install_tmp/work/lmline \$edition/config"
dollar_bin="$install_tmp/work/lmline \$edition/bin"
(
  cd "$install_tmp/work"
  HOME="$install_tmp/home" LMLINE_CONFIG_DIR="$dollar_config" LMLINE_BIN_DIR="$dollar_bin" \
    bash "project dir/install.sh" >"$install_tmp/dollar-install.out"
) || fail "installer failed with a literal-dollar config directory"

expected_dollar_config=$(CDPATH='' cd -- "$dollar_config" && pwd)
expected_dollar_bin=$(CDPATH='' cd -- "$dollar_bin" && pwd)
[[ -f "$expected_dollar_config/init.bash" && -f "$expected_dollar_config/init.zsh" ]] ||
  fail "literal-dollar config files were not installed"

# No other output line uses single quotes, so the quoted words in order are
# exactly the exported config dirs and command paths, including the config-dir
# word printed before each setup command. The pattern requires single quotes,
# so a double-quoted path (the reported bug) cannot satisfy it.
single_quoted_re="'([^']*)'"
printed_words=()
printed_exports=0
while IFS= read -r line; do
  if [[ $line == *"export LMLINE_CONFIG_DIR="* ]]; then
    export_tail=${line#*export LMLINE_CONFIG_DIR=}
    [[ $export_tail == "'"* ]] ||
      fail "config-dir export is not a literal quoted word: $line"
    printed_exports=$((printed_exports + 1))
  fi
  rest=$line
  while [[ $rest =~ $single_quoted_re ]]; do
    quoted=${BASH_REMATCH[0]}
    printed_words+=("${BASH_REMATCH[1]}")
    rest=${rest#*"$quoted"}
  done
done <"$install_tmp/dollar-install.out"
[[ $printed_exports -eq 6 ]] ||
  fail "expected 6 printed config-dir exports, got $printed_exports"

example_path="$expected_dollar_config/suggested_commands.txt"
expected_words=(
  "$expected_dollar_config"                           # temporary Bash trial export
  "$expected_dollar_config/init.bash"                 # temporary Bash --rcfile
  "$expected_dollar_config"                           # zsh trial export
  "$expected_dollar_config/init.zsh"                  # zsh trial source
  "$expected_dollar_config"                           # permanent Bash snippet export
  "$expected_dollar_config/init.bash"                 # ~/.bashrc snippet
  "$expected_dollar_config"                           # permanent zsh snippet export
  "$expected_dollar_config/init.zsh"                  # permanent zsh source
  "$expected_dollar_config"                           # standalone Bash completions export
  "$expected_dollar_config/completions/lmline.bash"   # standalone Bash completions
  "$expected_dollar_config"                           # standalone zsh completions export
  "$expected_dollar_config/completions"               # zsh fpath entry
  "$expected_dollar_bin"                              # PATH instruction
  "$expected_dollar_config/defaults"                  # editable lists
  "$example_path"                                     # override example (to be created)
)
[[ ${#printed_words[@]} -eq ${#expected_words[@]} ]] ||
  fail "expected ${#expected_words[@]} quoted words, got ${#printed_words[@]}"

for i in "${!expected_words[@]}"; do
  printed=${printed_words[i]}
  [[ $printed == "${expected_words[i]}" ]] ||
    fail "quoted word $i: expected ${expected_words[i]}, got $printed"
  [[ $printed == *'$edition'* ]] ||
    fail "quoted word $i lost its literal dollar sign: $printed"
  [[ $printed == *' '* ]] ||
    fail "quoted word $i lost its space: $printed"
  # The example is a file the user is told to create, not one we install.
  if [[ $printed != "$example_path" ]]; then
    [[ -e $printed ]] || fail "quoted word $i does not exist: $printed"
  fi
done

ok "printed setup commands are literal words for a dollar-sign config directory"

# A printed export must make fresh shells load the chosen config directory.
# The launcher below is built from the installer's own output and our own
# paths: no pasted or untrusted text is executed. The rcfile is read before
# -c commands, so the export belongs in the launching shell.
printf "export LMLINE_INSTALL_MARKER='from-custom-dir'\n" \
  >>"$expected_dollar_config/settings.bash"
printed_export=$(grep -m1 '^  export LMLINE_CONFIG_DIR=' "$install_tmp/dollar-install.out")
[[ -n $printed_export ]] || fail "temporary Bash trial has no printed config-dir export"
marker_probe='printf "MARKER=%s\n" "${LMLINE_INSTALL_MARKER:-UNSET}"'
run_marker_shell() {
  local setup=$1 output=$2
  {
    printf '%s\n' "$setup"
    printf 'exec bash --rcfile %q -ic %q </dev/null\n' \
      "$expected_dollar_config/init.bash" "$marker_probe"
  } >"$install_tmp/marker-setup.sh"
  env -i HOME="$install_tmp/home" PATH="$PATH" \
    bash "$install_tmp/marker-setup.sh" >"$output" 2>/dev/null
}

run_marker_shell ':' "$install_tmp/marker-control.out" ||
  fail "control marker shell failed"
grep -qx 'MARKER=UNSET' "$install_tmp/marker-control.out" ||
  fail "marker was set without the config-dir export"
run_marker_shell "${printed_export#  }" "$install_tmp/marker-export.out" ||
  fail "marker shell with the printed export failed"
grep -qx 'MARKER=from-custom-dir' "$install_tmp/marker-export.out" ||
  fail "printed export did not select the custom config directory"
ok "printed config-dir export selects custom settings in a fresh Bash shell"
