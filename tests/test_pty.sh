#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Ctrl-C must cancel the fallback's isolated job, not just its supervisor.
if command -v expect >/dev/null 2>&1; then
  cancel_pty_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-cancel-pty.XXXXXX")
  mkdir "$cancel_pty_tmp/bin"
  ln -s "$(command -v sleep)" "$cancel_pty_tmp/bin/sleep"
  # The leader exits on TERM but a same-group child ignores it. A broken
  # cancellation ends naturally after two seconds, leaving a marker well before
  # the five-second prompt timeout so timing failures remain distinguishable.
  cat >"$cancel_pty_tmp/worker" <<'WORKER'
printf 'worker_pid=%s worker_ppid=%s\n' "$$" "$PPID" >"$3"
trap 'printf "term\n" >"$2"; exit 0' TERM
(
  trap '' TERM
  printf 'cancel-ready\n'
  sleep 2
  printf 'leaked\n' >"$1"
) &
wait
WORKER
  cat >"$cancel_pty_tmp/cancel.exp" <<'EXPECT'
set timeout 5
log_user 1
lassign $argv shell root tmp
source "$root/tests/pty-expect-helpers.exp"
set term_file "$tmp/worker-term"
set pid_file "$tmp/worker-pids"
proc prompt {term_file pid_file} {
  expect {
    -re {CANCEL_PROMPT> $} {}
    timeout {
      puts stderr "cancellation PTY prompt timeout"
      if {[file exists $term_file]} {
        set f [open $term_file r]
        puts stderr "worker_term=[read $f]"
        close $f
      } else {
        puts stderr "worker_term=missing"
      }
      if {[file exists $pid_file]} {
        set f [open $pid_file r]
        puts stderr "worker_pids=[read $f]"
        close $f
      } else {
        puts stderr "worker_pids=missing"
      }
      if {[catch {exec ps -A -o pid,ppid,pgid} states]} {
        puts stderr "process_id_snapshot_unavailable=$states"
      } else {
        puts stderr "process_ids_at_timeout:\n$states"
      }
      exit 1
    }
    eof {puts stderr "cancellation PTY shell exited"; exit 1}
  }
}

spawn $shell --noprofile --norc -i
expect {
  -re {[$#] $} {}
  timeout {exit 1}
  eof {puts stderr "cancellation PTY shell exited before prompt"; exit 1}
}
send -- "unset PROMPT_COMMAND; PS1='CANCEL_PROMPT> '; source '$root/lmline/sandbox.bash'; export PATH='$tmp/bin'\r"
prompt "$term_file" "$pid_file"
send -- {if command -v timeout >/dev/null; then echo unexpected-timeout; else echo timeout-hidden; fi; command -v sleep >/dev/null && echo sleep-available; before=$-; before_traps=$(trap -p)}
send -- "\r"
expect_required -exact "\r\ntimeout-hidden\r\nsleep-available\r\n"
prompt "$term_file" "$pid_file"
send -- "__lmline_timeout_run 30 \"\$BASH\" '$tmp/worker' '$tmp/marker' '$term_file' '$pid_file'\r"
expect_required -exact "\r\ncancel-ready\r\n"
send -- "\003"
prompt "$term_file" "$pid_file"
# Read status in a new command: an interactive shell can discard the remainder
# of the interrupted input line. The returned prompt must remain usable.
send -- {printf 'cancel-status=%s\n' "$?"; [[ $- == "$before" && $(trap -p) == "$before_traps" ]] && echo caller-unchanged}
send -- "\r"
expect_required -exact "\r\ncancel-status=130\r\ncaller-unchanged\r\n"
prompt "$term_file" "$pid_file"
if {![file exists $term_file]} {
  puts stderr "cancellation PTY worker did not record TERM"
  exit 1
}
# Wait beyond the worker deadline, not merely the TERM grace period.
after 3000
if {[file exists "$tmp/marker"]} {
  puts stderr "cancellation PTY descendant leaked"
  exit 1
}
send -- "exit\r"
expect eof
EXPECT
  if ! expect "$cancel_pty_tmp/cancel.exp" "$BASH" "$repo_dir" "$cancel_pty_tmp" >"$cancel_pty_tmp/transcript" 2>&1; then
    cat "$cancel_pty_tmp/transcript" >&2
    rm -rf "$cancel_pty_tmp"
    fail "bash fallback timeout Ctrl-C cancellation PTY"
  fi
  rm -rf "$cancel_pty_tmp"
  ok "bash fallback timeout Ctrl-C cancellation PTY"
else
  printf 'skip - bash fallback timeout Ctrl-C cancellation PTY (expect not found)\n'
fi

if command -v expect >/dev/null 2>&1; then
  if expect <<EOF >/dev/null 2>&1
set timeout 1
source "$repo_dir/tests/pty-expect-helpers.exp"
spawn sh -c {printf 'lmline-progress: tool files\n'; read line}
expect_required "echo pty-suppressed"
EOF
  then
    fail "PTY required-candidate negative control accepted suppressed output"
  fi
  ok "PTY required-candidate assertion rejects suppressed output"
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
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 0
spawn bash --norc -i
expect_required "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0\r"
expect_required "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect_required "\\$ "
send "#request"
send "\030\007"
expect_required "echo pty-ok"
send "\025exit\r"
  expect eof
EOF
  expect <<EOF || fail "bash pty clip key binding"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 0
spawn bash --norc -i
expect_required "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-clip-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0 LMLINE_CLIPBOARD_PROVIDERS_FILE=$pty_tmp/clipboard.tsv LMLINE_CLIPBOARD_PROVIDER=fake\r"
expect_required "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect_required "\\$ "
send "\030\026"
expect_required "clipboard provider=fake"
expect_required "echo pty-ok"
send "\025exit\r"
expect eof
EOF
  # Keep PTY candidates short: long macOS TMPDIR paths wrap in Readline.
  bash_async_marker=$pty_tmp/bash-async-executed
  LMLINE_CONFIG_DIR=$pty_tmp/bash-async-config "$repo_dir/lmline/lmline" config set LMLINE_ASYNC 1 >/dev/null
  cat >"$pty_tmp/engine-async" <<EOF
#!/usr/bin/env bash
printf 'lmline-candidate: low\\tno matching risk rule\\t-\\ttouch bash-async-executed\\n'
EOF
  chmod +x "$pty_tmp/engine-async"
  expect <<EOF >"$pty_tmp/bash-async-reload.out" 2>&1 || fail "bash pty async setting reload before generation"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 1
spawn bash --norc -i
expect_required "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-async-config LMLINE_ENGINE=$pty_tmp/engine-async; cd '$pty_tmp'\r"
expect_required "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect_required "\\$ "
send "$repo_dir/lmline/lmline config set LMLINE_ASYNC 0\r"
expect_required "\\$ "
send "#request"
send "\030\007"
expect_required -exact "touch bash-async-executed"
send "\025"
send "exit\r"
expect eof
EOF
  ! grep -F "generating in background" "$pty_tmp/bash-async-reload.out" >/dev/null || fail "bash pty async setting reload should use synchronous route"
  [[ ! -e "$bash_async_marker" ]] || fail "bash pty candidate must not execute"
  expect <<EOF >"$pty_tmp/bash-next.out" 2>&1 || fail "bash pty next candidate"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 1
spawn bash --norc -i
expect_required "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-next-config LMLINE_ENGINE=$pty_tmp/engine-candidates LMLINE_ASYNC=0\r"
expect_required "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect_required "\\$ "
send "#request"
send "\030\007"
expect_required "echo one"
send "\030\016"
expect_required "echo two"
send "\030\016"
expect_required "echo three"
send "\025exit\r"
    expect eof
EOF
    expect <<EOF || fail "zsh pty clip key binding"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 0
spawn zsh -f
expect_required "% "
send "export PS1='ZSH_CLIP_''READY> '; export LMLINE_CONFIG_DIR=$pty_tmp/zsh-clip-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0 LMLINE_CLIPBOARD_PROVIDERS_FILE=$pty_tmp/clipboard.tsv LMLINE_CLIPBOARD_PROVIDER=fake\r"
expect_required "ZSH_CLIP_READY> "
send "source $repo_dir/lmline/init.zsh\r"
expect_required "ZSH_CLIP_READY> "
send "\030\026"
expect_required "clipboard provider=fake"
expect_required "echo pty-ok"
send "\025exit\r"
expect eof
EOF
  grep -q "3 candidates; m=pty-model; tok=70/7/77" "$pty_tmp/bash-next.out" || fail "bash pty next should show candidate count and model metadata"
  grep -q "2/3" "$pty_tmp/bash-next.out" || fail "bash pty next should show candidate position while cycling"
  grep -q "3/3" "$pty_tmp/bash-next.out" || fail "bash pty second next should advance candidate position"
  bash_next_norm=$(tr '\r' '\n' <"$pty_tmp/bash-next.out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
  ! grep -E 'candidates.*echo one|candidates.*echo two|candidates.*echo three' <<<"$bash_next_norm" >/dev/null || fail "bash pty candidate count shares edit line"
  printf '#!/usr/bin/env bash\nsleep 0.15\nprintf "lmline-progress: tool files (openai, round 1/10)\\n" >&2\nsleep 0.2\ncase " $* " in *" --mode explain "*) printf "explained pty\\n";; *) printf "lmline-candidate: low\\tno matching risk rule\\t-\\techo pty-slow\\n";; esac\n' >"$pty_tmp/engine-slow"
  chmod +x "$pty_tmp/engine-slow"
  expect <<EOF >"$pty_tmp/bash-spinner.out" 2>&1 || fail "bash pty spinner"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 1
spawn bash --norc -i
expect_required "\\$ "
send "export LMLINE_CONFIG_DIR=$pty_tmp/bash-spinner-config LMLINE_ENGINE=$pty_tmp/engine-slow LMLINE_ASYNC=0 LMLINE_SPINNER=1 LMLINE_SPINNER_INTERVAL=0.1\r"
expect_required "\\$ "
send "source $repo_dir/lmline/init.bash\r"
expect_required "\\$ "
send "echo old"
send "\030\022"
expect_required "\\[rewrite\\]"
expect_required "tool files"
expect_required "echo pty-slow"
send "\025echo hi"
send "\030\005"
expect_required_spinner_and_explanation
send "\025exit\r"
expect eof
EOF
  ! grep -E '\[[0-9]+\]|終了|Done|__lmline_call_engine_raw' "$pty_tmp/bash-spinner.out" >/dev/null || fail "bash pty spinner job noise"
  bash_spinner_norm=$(tr '\r' '\n' <"$pty_tmp/bash-spinner.out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
  ! grep -E '\[rewrite\].*(bash.*\$|echo pty-slow)' <<<"$bash_spinner_norm" >/dev/null || fail "bash pty spinner left rewrite text on prompt line"
  ! grep -E 'explaining.*(bash.*\$|explained pty)' <<<"$bash_spinner_norm" >/dev/null || fail "bash pty spinner left explain text on output line"
  if command -v zsh >/dev/null 2>&1; then
    zsh_async_marker=$pty_tmp/zsh-async-executed
    LMLINE_CONFIG_DIR=$pty_tmp/zsh-async-config "$repo_dir/lmline/lmline" config set LMLINE_ASYNC 1 >/dev/null
    cat >"$pty_tmp/engine-zsh-async" <<EOF
#!/usr/bin/env bash
printf 'lmline-candidate: low\\tno matching risk rule\\t-\\ttouch zsh-async-executed\\n'
EOF
    chmod +x "$pty_tmp/engine-zsh-async"
    expect <<EOF >"$pty_tmp/zsh-async-reload.out" 2>&1 || fail "zsh pty async setting reload before generation"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 1
spawn zsh -f
expect_required "% "
send "export PS1='ZSH_ASYNC_''READY> '; export LMLINE_CONFIG_DIR=$pty_tmp/zsh-async-config LMLINE_ENGINE=$pty_tmp/engine-zsh-async; cd '$pty_tmp'\r"
expect_required "ZSH_ASYNC_READY> "
send "source $repo_dir/lmline/init.zsh\r"
expect_required "ZSH_ASYNC_READY> "
send "$repo_dir/lmline/lmline config set LMLINE_ASYNC 0\r"
expect_required "ZSH_ASYNC_READY> "
send "#request"
send "\030\007"
expect_required -exact "touch zsh-async-executed"
send "\025"
send "exit\r"
expect eof
EOF
    ! grep -F "generating in background" "$pty_tmp/zsh-async-reload.out" >/dev/null || fail "zsh pty async setting reload should use synchronous route"
    [[ ! -e "$zsh_async_marker" ]] || fail "zsh pty candidate must not execute"
    expect <<EOF || fail "zsh pty key binding"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 0
spawn zsh -f
expect_required "% "
send "export PS1='ZSH_KEYS_''READY> '; export LMLINE_CONFIG_DIR=$pty_tmp/zsh-config LMLINE_ENGINE=$pty_tmp/engine LMLINE_ASYNC=0\r"
expect_required "ZSH_KEYS_READY> "
send "source $repo_dir/lmline/init.zsh\r"
expect_required "ZSH_KEYS_READY> "
send "#request"
send "\030\007"
expect_required "echo pty-ok"
send "\025exit\r"
expect eof
EOF
    expect <<EOF >"$pty_tmp/zsh-spinner.out" 2>&1 || fail "zsh pty spinner"
set timeout 5
source "$repo_dir/tests/pty-expect-helpers.exp"
log_user 1
spawn zsh -f
expect_required "% "
send "export PS1='ZSH_SPINNER_''READY> '; export LMLINE_CONFIG_DIR=$pty_tmp/zsh-spinner-config LMLINE_ENGINE=$pty_tmp/engine-slow LMLINE_ASYNC=0 LMLINE_SPINNER=1 LMLINE_SPINNER_INTERVAL=0.1\r"
expect_required "ZSH_SPINNER_READY> "
send "source $repo_dir/lmline/init.zsh\r"
expect_required "ZSH_SPINNER_READY> "
send "echo old"
send "\030\022"
expect_required "\\[rewrite\\]"
expect_required "tool files"
expect_required "echo pty-slow"
send "\025echo hi"
send "\030\005"
expect_required_spinner_and_explanation
send "\025exit\r"
expect eof
EOF
    ! grep -E '\[[0-9]+\]|終了|Done|__lmline_zsh_bridge' "$pty_tmp/zsh-spinner.out" >/dev/null || fail "zsh pty spinner job noise"
    zsh_spinner_norm=$(tr '\r' '\n' <"$pty_tmp/zsh-spinner.out" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
    ! grep -E '\[rewrite\].*(ZSH_SPINNER_READY> |echo pty-slow)' <<<"$zsh_spinner_norm" >/dev/null || fail "zsh pty spinner left rewrite text on prompt line"
    ! grep -E 'explaining.*(ZSH_SPINNER_READY> |explained pty)' <<<"$zsh_spinner_norm" >/dev/null || fail "zsh pty spinner left explain text on output line"
  fi
  rm -rf "$pty_tmp"
  ok "pty key bindings"
else
  printf 'skip - pty key bindings (expect not found)\n'
fi

# Classify the raw candidate in a tiny replacement engine, then exercise the
# normal protocol -> widget -> review-comment path in actual interactive
# shells. The synthetic event breaks out of double quotes: without the review
# comment, Enter would execute the marker (verified by the positive control).
if command -v expect >/dev/null 2>&1; then
  history_pty_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-history-pty.XXXXXX")
  cat >"$history_pty_tmp/engine" <<'ENGINE'
#!/usr/bin/env bash
set -euo pipefail
source "$LMLINE_PTY_ROOT/lmline/policy.bash"
candidate='echo "!!"'
printf 'lmline-candidate: %s\t%s\t-\t%s\n' \
  "$(__lmline_risk_level "$candidate")" "$(__lmline_risk_reason "$candidate")" "$candidate"
ENGINE
  chmod +x "$history_pty_tmp/engine"
  history_protocol=$(LMLINE_CONFIG_DIR="$history_pty_tmp/protocol-config" LMLINE_PTY_ROOT="$repo_dir" "$history_pty_tmp/engine")
  [[ $history_protocol == $'lmline-candidate: high\tinteractive history expansion\t-\techo "!!"' ]] || fail "history risk protocol preserves candidate"
  cat >"$history_pty_tmp/review.exp" <<'EXPECT'
set timeout 5
log_user 0
lassign $argv shell root tmp
set marker "$tmp/$shell-executed"
proc prompt {} {
  expect {
    -re {[\r\n]HISTORY_PROMPT> } {}
    timeout {puts stderr "history PTY prompt timeout"; exit 1}
    eof {puts stderr "history PTY unexpected eof"; exit 1}
  }
}
if {$shell eq "bash"} {
  spawn env HISTFILE=/dev/null HISTSIZE=1000 bash --noprofile --norc -i
} else {
  spawn env HISTFILE=/dev/null HISTSIZE=1000 zsh -f
}
expect {
  -re {[$%] } {}
  timeout {exit 1}
  eof {puts stderr "history PTY shell exited before prompt"; exit 1}
}
send -- "PS1='HISTORY_PROMPT> '; export LMLINE_CONFIG_DIR=$tmp/$shell-config LMLINE_PTY_ROOT=$root LMLINE_ENGINE=$tmp/engine LMLINE_ASYNC=0 LMLINE_SPINNER=0\r"
prompt
send -- "source $root/lmline/init.$shell\r"
prompt
set event "\"; touch $marker; echo \""
if {$shell eq "bash"} {
  set seed "history -s '$event'"
} else {
  set seed "print -s -- '$event'"
}
# Positive control: the event must really execute if submitted without review.
send -- "$seed\r"
prompt
send -- {echo "!!"}
send -- "\r"
prompt
if {![file exists $marker]} {
  puts stderr "history PTY positive control did not execute marker"
  exit 1
}
file delete $marker
send -- "$seed\r"
prompt
send -- "#request"
send -- "\030\007"
expect {
  -exact {# REVIEW REQUIRED: echo "!!"} {}
  timeout {puts stderr "history PTY missing unchanged review comment"; exit 1}
  eof {puts stderr "history PTY exited before review comment"; exit 1}
}
send -- "\r"
prompt
if {[file exists $marker]} {
  puts stderr "history PTY review comment executed marker"
  exit 1
}
send -- "exit\r"
expect eof
EXPECT
  for history_shell in bash zsh; do
    if command -v "$history_shell" >/dev/null 2>&1; then
      expect "$history_pty_tmp/review.exp" "$history_shell" "$repo_dir" "$history_pty_tmp" || fail "$history_shell history risk review PTY"
      ok "$history_shell history risk review PTY"
    else
      printf 'skip - %s history risk review PTY (shell not found)\n' "$history_shell"
    fi
  done
  rm -rf "$history_pty_tmp"
else
  printf 'skip - history risk review PTY (expect not found)\n'
fi
