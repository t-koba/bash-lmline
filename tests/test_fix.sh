#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

fix_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-fix-widget.XXXXXX")
printf '#!/usr/bin/env bash\nmode=\nline_file=\nwhile (($#)); do case "$1" in --mode) mode=$2; shift 2;; --line-file) line_file=$2; shift 2;; *) shift;; esac; done\nif [[ "$mode" == fix ]]; then grep -q "exit_status=" "$line_file" && printf "lmline-candidate: low\\tno matching risk rule\\t-\\techo fixed\\n"; else printf "lmline-candidate: low\\tno matching risk rule\\t-\\techo default\\n"; fi\n' >"$fix_tmp/engine"
chmod +x "$fix_tmp/engine"
LMLINE_CONFIG_DIR="$fix_tmp/config" LMLINE_ASYNC=0 LMLINE_ENGINE="$fix_tmp/engine" LMLINE_HISTORY_DIR="$fix_tmp/history" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="false"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_fix_widget >/tmp/lmline-widget-fix.out 2>/tmp/lmline-widget-fix.err
  [[ "$READLINE_LINE" == "echo fixed" ]]
' _ "$repo_dir" || fail "fix widget"
LMLINE_CONFIG_DIR="$fix_tmp/config" LMLINE_ENGINE="$fix_tmp/engine" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="rm -rf build"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_fix_widget >/tmp/lmline-widget-fix-risk.out 2>/tmp/lmline-widget-fix-risk.err
  [[ "$READLINE_LINE" == "rm -rf build" ]]
' _ "$repo_dir" || fail "fix high-risk refusal"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'while (($#)); do case "$1" in --mode) mode=$2; shift 2;; *) shift;; esac; done' \
  'if [[ "$mode" == fix ]]; then' \
  '  printf "lmline-candidate: low\tno matching risk rule\t-\techo corrected\n"' \
  'fi' >"$fix_tmp/engine"
chmod +x "$fix_tmp/engine"
LMLINE_CONFIG_DIR="$fix_tmp/config2" LMLINE_ENGINE="$fix_tmp/engine" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="false"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_fix_widget >/tmp/lmline-widget-fix-same.out 2>/tmp/lmline-widget-fix-same.err
  [[ "$READLINE_LINE" == "echo corrected" ]]
' _ "$repo_dir" || fail "fix uses engine correction"
LMLINE_CONFIG_DIR="$fix_tmp/config3" LMLINE_ENGINE="$fix_tmp/engine" bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="echo corrected"
  READLINE_POINT=${#READLINE_LINE}
  __lmline_fix_widget >/tmp/lmline-widget-fix-ok.out 2>/tmp/lmline-widget-fix-ok.err
  [[ "$READLINE_LINE" == "echo corrected" ]]
  grep -q "command succeeded; no fix needed" /tmp/lmline-widget-fix-ok.err
' _ "$repo_dir" || fail "fix successful command"
rm -rf "$fix_tmp"
ok "fix widget"
