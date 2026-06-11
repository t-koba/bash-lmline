#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if command -v expect >/dev/null 2>&1; then
  pty_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-pty.XXXXXX")
  printf '#!/usr/bin/env bash\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo pty-ok\\n"\n' >"$pty_tmp/engine"
  chmod +x "$pty_tmp/engine"
  printf '#!/usr/bin/env bash\nprintf "pty clipboard text\\n"\n' >"$pty_tmp/fakeclip"
  chmod +x "$pty_tmp/fakeclip"
  printf 'fake\t%s\n' "$pty_tmp/fakeclip" >"$pty_tmp/clipboard.tsv"
  printf '#!/usr/bin/env bash\nprintf "lmline-status: m=pty-model; tok=70/7/77\\n" >&2\nprintf "lmline-candidate: low\\tno matching risk rule\\t-\\techo one\\nlmline-candidate: low\\tno matching risk rule\\t-\\techo two\\nlmline-candidate: low\\tno matching risk rule\\t-\\techo three\\n"\n' >"$pty_tmp/engine-candidates"
  chmod +x "$pty_tmp/engine-candidates"
  expect <<EOF || fail "bash pty key binding"
set timeout 5
log_user 0
spawn bash --norc -i
expect "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0\r"
expect "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect "\\$ "
send "#request"
send "\030\007"
expect {
  "echo pty-ok" {}
  timeout { exit 1 }
}
send "\025exit\r"
  expect eof
EOF
  expect <<EOF || fail "bash pty clip key binding"
set timeout 5
log_user 0
spawn bash --norc -i
expect "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-clip-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0 LMLINE_CLIPBOARD_PROVIDERS_FILE=$pty_tmp/clipboard.tsv LMLINE_CLIPBOARD_PROVIDER=fake\r"
expect "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect "\\$ "
send "\030\026"
expect "clipboard provider=fake"
expect "echo pty-ok"
send "\025exit\r"
expect eof
EOF
  expect <<EOF >"$pty_tmp/bash-next.out" 2>&1 || fail "bash pty next candidate"
set timeout 5
log_user 1
spawn bash --norc -i
expect "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-next-config LMLINE_ENGINE=$pty_tmp/engine-candidates LMLINE_ASYNC=0\r"
expect "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect "\\$ "
send "#request"
send "\030\007"
expect "echo one"
send "\030\016"
expect "echo two"
send "\030\016"
expect "echo three"
send "\025exit\r"
    expect eof
EOF
    expect <<EOF || fail "zsh pty clip key binding"
set timeout 5
log_user 0
spawn zsh -f
expect "% "
send "export LMLINE_CONFIG_DIR=$pty_tmp/zsh-clip-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0 LMLINE_CLIPBOARD_PROVIDERS_FILE=$pty_tmp/clipboard.tsv LMLINE_CLIPBOARD_PROVIDER=fake\r"
expect "% "
send "source $repo_dir/lmline/init.zsh\r"
expect "% "
send "\030\026"
expect "clipboard provider=fake"
expect "echo pty-ok"
send "\025exit\r"
expect eof
EOF
  grep -q "3 candidates; m=pty-model; tok=70/7/77" "$pty_tmp/bash-next.out" || fail "bash pty next should show candidate count and model metadata"
  ! grep -Eq "[123]/3" "$pty_tmp/bash-next.out" || fail "bash pty next should not show candidate position"
  bash_next_norm=$(tr '\r' '\n' <"$pty_tmp/bash-next.out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
  ! grep -E 'candidates.*echo one|candidates.*echo two|candidates.*echo three' <<<"$bash_next_norm" >/dev/null || fail "bash pty candidate count shares edit line"
  printf '#!/usr/bin/env bash\nsleep 0.15\nprintf "lmline-progress: tool files (openai, round 1/10)\\n" >&2\nsleep 0.2\ncase " $* " in *" --mode explain "*) printf "explained pty\\n";; *) printf "lmline-candidate: low\\tno matching risk rule\\t-\\techo pty-slow\\n";; esac\n' >"$pty_tmp/engine-slow"
  chmod +x "$pty_tmp/engine-slow"
  expect <<EOF >"$pty_tmp/bash-spinner.out" 2>&1 || fail "bash pty spinner"
set timeout 5
log_user 1
spawn bash --norc -i
expect "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-spinner-config LMLINE_ENGINE=$pty_tmp/engine-slow LMLINE_ASYNC=0 LMLINE_SPINNER=1 LMLINE_SPINNER_INTERVAL=0.1\r"
expect "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect "\\$ "
send "echo old"
send "\030\022"
expect "\\[rewrite\\]"
expect "tool files"
expect "echo pty-slow"
send "\025echo hi"
send "\030\005"
expect "explaining"
expect "explained pty"
send "\025exit\r"
expect eof
EOF
  ! grep -E '\[[0-9]+\]|終了|Done|__lmline_call_engine_raw' "$pty_tmp/bash-spinner.out" >/dev/null || fail "bash pty spinner job noise"
  bash_spinner_norm=$(tr '\r' '\n' <"$pty_tmp/bash-spinner.out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
  ! grep -E '\[rewrite\].*(bash.*\$|echo pty-slow)' <<<"$bash_spinner_norm" >/dev/null || fail "bash pty spinner left rewrite text on prompt line"
  ! grep -E 'explaining.*(bash.*\$|explained pty)' <<<"$bash_spinner_norm" >/dev/null || fail "bash pty spinner left explain text on output line"
  if command -v zsh >/dev/null 2>&1; then
    expect <<EOF || fail "zsh pty key binding"
set timeout 5
log_user 0
spawn zsh -f
expect "% "
send "export LMLINE_CONFIG_DIR=$pty_tmp/zsh-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0\r"
expect "% "
send "source $repo_dir/lmline/init.zsh\r"
expect "% "
send "#request"
send "\030\007"
expect {
  "echo pty-ok" {}
  timeout { exit 1 }
}
send "\025exit\r"
expect eof
EOF
    expect <<EOF >"$pty_tmp/zsh-spinner.out" 2>&1 || fail "zsh pty spinner"
set timeout 5
log_user 1
spawn zsh -f
expect "% "
send "export LMLINE_CONFIG_DIR=$pty_tmp/zsh-spinner-config LMLINE_ENGINE=$pty_tmp/engine-slow LMLINE_ASYNC=0 LMLINE_SPINNER=1 LMLINE_SPINNER_INTERVAL=0.1\r"
expect "% "
send "source $repo_dir/lmline/init.zsh\r"
expect "% "
send "echo old"
send "\030\022"
expect "\\[rewrite\\]"
expect "tool files"
expect "echo pty-slow"
send "\025echo hi"
send "\030\005"
expect "explaining"
expect "explained pty"
send "\025exit\r"
expect eof
EOF
    ! grep -E '\[[0-9]+\]|終了|Done|__lmline_zsh_bridge' "$pty_tmp/zsh-spinner.out" >/dev/null || fail "zsh pty spinner job noise"
    zsh_spinner_norm=$(tr '\r' '\n' <"$pty_tmp/zsh-spinner.out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
    ! grep -E '\[rewrite\].*(% |echo pty-slow)' <<<"$zsh_spinner_norm" >/dev/null || fail "zsh pty spinner left rewrite text on prompt line"
    ! grep -E 'explaining.*(% |explained pty)' <<<"$zsh_spinner_norm" >/dev/null || fail "zsh pty spinner left explain text on output line"
  fi
  rm -rf "$pty_tmp"
  ok "pty key bindings"
else
  printf 'skip - pty key bindings (expect not found)\n'
fi
