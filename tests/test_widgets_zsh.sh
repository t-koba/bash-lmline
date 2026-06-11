#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if command -v zsh >/dev/null 2>&1; then
  zsh_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-zsh-widget.XXXXXX")
  printf '#!/usr/bin/env bash\nsleep 0.2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-widget\\n"\n' >"$zsh_tmp/engine"
  chmod +x "$zsh_tmp/engine"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-sync" LMLINE_ENGINE="$zsh_tmp/engine" zsh -fic '
    source "$1/lmline/init.zsh"
    [[ "$options[interactivecomments]" == on ]]
    [[ $(__lmline_zsh_mode "?") == generate ]]
    [[ $(__lmline_zsh_mode "? request") == generate ]]
    [[ $(__lmline_zsh_mode "?foo") == rewrite ]]
    [[ $(__lmline_zsh_mode "ls | ") == continue ]]
    [[ $(__lmline_zsh_mode "ls |") == continue ]]
    BUFFER="# say one"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-1.out 2>/tmp/lmline-zsh-widget-1.err
    [[ "$BUFFER" == "echo zsh-widget" ]]
  ' _ "$repo_dir" || fail "zsh sync widget"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-async" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="# say one"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-async-1.out 2>/tmp/lmline-zsh-widget-async-1.err
    [[ "$BUFFER" == "# say one" ]]
    [[ -z $(jobs) ]]
    sleep 1
    lmline-zsh-generate-widget >/tmp/lmline-zsh-widget-async-2.out 2>/tmp/lmline-zsh-widget-async-2.err
    [[ "$BUFFER" == "echo zsh-widget" ]]
  ' _ "$repo_dir" || fail "zsh async widget"
  printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: synthetic zsh async failure\\n" >&2\nexit 1\n' >"$zsh_tmp/engine-async-fail"
  chmod +x "$zsh_tmp/engine-async-fail"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-async-fail" LMLINE_ASYNC=1 LMLINE_ENGINE="$zsh_tmp/engine-async-fail" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="# fail"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-async-fail1.out 2>/tmp/lmline-zsh-async-fail1.err
    sleep 1
    lmline-zsh-generate-widget >/tmp/lmline-zsh-async-fail2.out 2>/tmp/lmline-zsh-async-fail2.err
    grep -q "synthetic zsh async failure" /tmp/lmline-zsh-async-fail2.err
  ' _ "$repo_dir" || fail "zsh async failure hint"
  LMLINE_CONFIG_DIR="$zsh_tmp/config2" LMLINE_ASYNC=0 LMLINE_ENGINE="$zsh_tmp/engine" zsh -fic '
    source "$1/lmline/init.zsh"
    [[ $(__lmline_zsh_bridge generate generate "# say one" 0) == "lmline-candidate: low"*"echo zsh-widget" ]]
  ' _ "$repo_dir" || fail "zsh bridge"
  printf '#!/usr/bin/env bash\nmode=\nwhile (($#)); do case "$1" in --mode) mode=$2; shift 2;; *) shift;; esac; done\nif [[ "$mode" == explain ]]; then printf "zsh explained\\n"; else printf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-widget\\n"; fi\n' >"$zsh_tmp/engine-explain"
  chmod +x "$zsh_tmp/engine-explain"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-explain" LMLINE_PS0="[lm] " LMLINE_ENGINE="$zsh_tmp/engine-explain" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="echo hi"
    CURSOR=${#BUFFER}
    lmline-zsh-explain-widget >/tmp/lmline-zsh-explain.out 2>/tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] command: echo hi" /tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] risk=low" /tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] command summary:" /tmp/lmline-zsh-explain.err
    grep -q "\\[lm\\] model explanation:" /tmp/lmline-zsh-explain.err
    grep -q "zsh explained" /tmp/lmline-zsh-explain.err
  ' _ "$repo_dir" || fail "zsh explain widget"
  printf '#!/usr/bin/env bash\nprintf "lmline-engine: request failed: curl: (28) Operation timed out after 12003 milliseconds with 0 bytes received\\n" >&2\nexit 1\n' >"$zsh_tmp/engine-fail"
  chmod +x "$zsh_tmp/engine-fail"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-fail" LMLINE_ENGINE="$zsh_tmp/engine-fail" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="# say one"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-fail.out 2>/tmp/lmline-zsh-fail.err
    [[ "$BUFFER" == "# say one" ]]
    grep -q "request timed out" /tmp/lmline-zsh-fail.err
    grep -q "LMLINE_ENGINE_TIMEOUT" /tmp/lmline-zsh-fail.err
  ' _ "$repo_dir" || fail "zsh engine failure is surfaced"
  printf '#!/usr/bin/env bash\nprintf "lmline-status: m=zsh-model; tok=80/8/88\\n" >&2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-one\\nlmline-candidate: low\\tno matching risk rule\\t-\\techo zsh-two\\n"\n' >"$zsh_tmp/engine"
  chmod +x "$zsh_tmp/engine"
  LMLINE_CONFIG_DIR="$zsh_tmp/config4" LMLINE_ASYNC=0 LMLINE_ENGINE="$zsh_tmp/engine" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER=""
    CURSOR=0
    lmline-zsh-rewrite-widget >/tmp/lmline-zsh-rewrite-empty.out 2>/tmp/lmline-zsh-rewrite-empty.err
    [[ "$BUFFER" == "" ]]
    BUFFER="echo old"
    CURSOR=${#BUFFER}
    lmline-zsh-rewrite-widget >/tmp/lmline-zsh-rewrite.out 2>/tmp/lmline-zsh-rewrite.err
    [[ "$BUFFER" == "echo zsh-one" ]]
    grep -q "3 candidates; m=zsh-model; tok=80/8/88" /tmp/lmline-zsh-rewrite.err
    lmline-zsh-next-widget
    [[ "$BUFFER" == "echo zsh-two" ]]
    ! grep -q "2/3" /tmp/lmline-zsh-rewrite.err
    lmline-zsh-next-widget
    [[ "$BUFFER" == "echo old" ]]
    ! grep -q "3/3" /tmp/lmline-zsh-rewrite.err
    lmline-zsh-prev-widget
    [[ "$BUFFER" == "echo zsh-two" ]]
    test -s "$LMLINE_HISTORY_DIR/suggestions.log"
  ' _ "$repo_dir" || fail "zsh rewrite candidate cycling"
  printf '#!/usr/bin/env bash\nprintf "lmline-candidate: medium\\twrites to a file or descriptor\\t-\\techo hi > out.txt\\n"\n' >"$zsh_tmp/engine-medium"
  chmod +x "$zsh_tmp/engine-medium"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-medium" LMLINE_ENGINE="$zsh_tmp/engine-medium" LMLINE_HISTORY_DIR="$zsh_tmp/history-medium" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="# medium"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-medium.out 2>/tmp/lmline-zsh-medium.err
    [[ "$BUFFER" == "echo hi > out.txt" ]]
    grep -q "medium-risk; review before Enter" /tmp/lmline-zsh-medium.err
    grep -q "candidate=" "$LMLINE_HISTORY_DIR/suggestions.log"
  ' _ "$repo_dir" || fail "zsh medium risk and history"
  printf '#!/usr/bin/env bash\nprintf "lmline-candidate: high\\trecursive remove\\t-\\trm -rf /tmp/lmline-zsh-risk-test\\n"\n' >"$zsh_tmp/engine-high"
  chmod +x "$zsh_tmp/engine-high"
  LMLINE_CONFIG_DIR="$zsh_tmp/config-high" LMLINE_ENGINE="$zsh_tmp/engine-high" zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="# high"
    CURSOR=${#BUFFER}
    lmline-zsh-generate-widget >/tmp/lmline-zsh-high.out 2>/tmp/lmline-zsh-high.err
    [[ "$BUFFER" == "# REVIEW REQUIRED: rm -rf /tmp/lmline-zsh-risk-test" ]]
    grep -q "high-risk; inserted as comment" /tmp/lmline-zsh-high.err
  ' _ "$repo_dir" || fail "zsh high risk hint"
  rm -rf "$zsh_tmp"
  ok "zsh integration"
else
  printf 'skip - zsh integration (zsh not found)\n'
fi
