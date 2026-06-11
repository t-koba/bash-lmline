#!/usr/bin/env bash
set -euo pipefail

src_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_dir=${LMLINE_CONFIG_DIR:-$HOME/.config/lmline}
bin_dir=${LMLINE_BIN_DIR:-$HOME/.local/bin}
config_file=$config_dir/settings.bash

mkdir -p "$config_dir" "$config_dir/history" "$bin_dir"

for path in init.bash init.zsh config.bash context.bash policy.bash actions.bash http.bash profiles.bash chat.bash engine lmline; do
  install -m 0755 "$src_dir/lmline/$path" "$config_dir/$path"
done

mkdir -p "$config_dir/prompts"
for path in "$src_dir"/lmline/prompts/*.txt; do
  install -m 0644 "$path" "$config_dir/prompts/$(basename "$path")"
done

mkdir -p "$config_dir/defaults"
for path in "$src_dir"/lmline/defaults/*.txt "$src_dir"/lmline/defaults/*.tsv; do
  install -m 0644 "$path" "$config_dir/defaults/$(basename "$path")"
done

ln -sf "$config_dir/lmline" "$bin_dir/lmline"

# shellcheck source=lmline/config.bash
source "$src_dir/lmline/config.bash"

install_config_has() {
  [[ -f "$config_file" ]] && grep -Eq "^export $1=" "$config_file"
}

install_config_set_if_unset() {
  local key=$1 value=$2 tmp
  install_config_has "$key" && return 1
  touch "$config_file"
  tmp=$(mktemp "${TMPDIR:-/tmp}/lmline-cfg.XXXXXX")
  grep -v -E "^export ${key}=" "$config_file" >"$tmp" || true
  printf 'export %s=%s\n' "$key" "$(__lmline_quote_single "$value")" >>"$tmp"
  mv "$tmp" "$config_file"
  chmod 600 "$config_file" 2>/dev/null || true
  return 0
}

detect_clipboard_provider() {
  local item name cmd os
  os=$(uname -s 2>/dev/null || printf unknown)
  case "$os" in
    Darwin)
      set -- macos:pbpaste tmux:tmux wayland:wl-paste xclip:xclip xsel:xsel wsl:powershell.exe
      ;;
    Linux)
      set -- wayland:wl-paste xclip:xclip xsel:xsel wsl:powershell.exe tmux:tmux
      ;;
    *)
      set -- macos:pbpaste wayland:wl-paste xclip:xclip xsel:xsel wsl:powershell.exe tmux:tmux
      ;;
  esac
  for item in "$@"; do
    name=${item%%:*}
    cmd=${item#*:}
    if command -v "$cmd" >/dev/null 2>&1; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

clipboard_note="Clipboard provider: not configured (no supported clipboard reader found)"
if install_config_has LMLINE_CLIPBOARD_PROVIDER; then
  clipboard_note="Clipboard provider: preserved existing LMLINE_CLIPBOARD_PROVIDER"
elif clipboard_provider=$(detect_clipboard_provider); then
  if install_config_set_if_unset LMLINE_CLIPBOARD_PROVIDER "$clipboard_provider"; then
    clipboard_note="Clipboard provider: configured $clipboard_provider"
  fi
fi

cat <<EOF
Installed lmline to $config_dir

lmline provides Bash Readline and zsh ZLE integrations.
The Bash integration and bundled engine require bash 4.2 or newer.

For a temporary Bash trial:

  bash --rcfile "$config_dir/init.bash" -i

For a zsh trial:

  source "$config_dir/init.zsh"

For permanent Bash use, add this to ~/.bashrc if it is not already present:

if [[ \$- == *i* ]]; then
  source "$config_dir/init.bash"
fi

For permanent zsh use, add this to ~/.zshrc if it is not already present:

source "$config_dir/init.zsh"

Optional defaults:
  lmline endpoint add lmstudio http://127.0.0.1:1234/v1
  lmline model refresh lmstudio
  lmline use lmstudio <model-id>
  lmline config set LMLINE_TOOL_MODE auto
  lmline endpoint set-secret <endpoint>   # only for authenticated endpoints

$clipboard_note
Clipboard commands:
  lmline clip --status
  lmline clip --providers
  lmline clip --use <provider>

Equivalent environment variables:
  export LMLINE_BASE_URL=http://127.0.0.1:1234/v1
  export LMLINE_MODEL=<model-id>
  export LMLINE_API_KEY_FILE=<path-to-api-key-file>

Make sure $bin_dir is on PATH if you want to run: lmline doctor
Use "lmline doctor --check-api" to also test provider connectivity.

Editable lists and policy defaults were installed under:
  $config_dir/defaults

To override a default without changing installed files, create a file with the
same name directly under $config_dir, for example:
  $config_dir/suggested_commands.txt
EOF
