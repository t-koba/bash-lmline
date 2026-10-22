#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: Copilot LSP request/reply, daemon lifecycle, completion, and async widget integration remain correct.

# Polls for an asynchronously appended LSP log line. Fire-and-forget
# notifications (didShowCompletion/didClose) are written by the fake server
# after the daemon already replied, so a single immediate grep flakes on
# loaded runners (observed as a silent macOS CI failure).
copilot_wait_log() {
  local pattern=$1 file=$2 i
  for ((i = 0; i < 100; i++)); do
    grep -q -- "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

copilot_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-copilot-test.XXXXXX")
copilot_runtime="$repo_dir/.copilot-test-run.$$"
mkdir -p "$copilot_runtime"
trap 'LMLINE_CONFIG_DIR="$copilot_tmp/config" LMLINE_COPILOT_RUNTIME_DIR="$copilot_runtime" node "$repo_dir/lmline/copilot-client.js" restart >/dev/null 2>&1 || true; rm -rf "$copilot_tmp" "$copilot_runtime"' EXIT
mkdir -p "$copilot_tmp/config"

copilot_env=(
  LMLINE_CONFIG_DIR="$copilot_tmp/config"
  LMLINE_COPILOT_RUNTIME_DIR="$copilot_runtime"
  LMLINE_COPILOT_COMMAND="$repo_dir/tests/fake_copilot_ls.js"
  LMLINE_FAKE_COPILOT_LOG="$copilot_tmp/lsp.log"
  LMLINE_COPILOT_OPEN_LOG="$copilot_tmp/open.log"
  LMLINE_COPILOT_TIMEOUT=3000
)

edit_out=$(env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" edit 'echo 😀 old' 10 "$repo_dir") || {
  sed -n '1,80p' "$copilot_runtime/daemon.log" >&2 || true
  fail "Copilot inline edit"
}
grep -q $'\techo 😀 new$' <<<"$edit_out" || fail "UTF-16 edit application"
[[ $(wc -l <<<"$edit_out" | tr -d ' ') == 2 ]] || fail "multiline edit rejected"
token=${edit_out%%$'\t'*}
env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" accept "$token" >/dev/null || fail "Copilot acceptance"
grep -q 'github.copilot.didAcceptCompletionItem' "$copilot_tmp/lsp.log" || fail "acceptance command forwarded"
grep -q '^workspace/configuration-response$' "$copilot_tmp/lsp.log" || fail "server configuration request handled"

status_out=$(env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" status) || fail "Copilot status"
grep -q '^status=NotSignedIn$' <<<"$status_out" || fail "Copilot status output"
login_out=$(env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" login) || fail "Copilot login"
grep -q '^user_code=TEST-CODE$' <<<"$login_out" || fail "Copilot device code"
grep -q '^browser_opened=1$' <<<"$login_out" || fail "Copilot login opens browser after code"
copilot_wait_log '^showDocument-success=true$' "$copilot_tmp/lsp.log" || fail "Copilot simulated launcher reports LSP success"
[[ $(wc -l <"$copilot_tmp/open.log" | tr -d ' ') == 1 ]] || fail "Copilot browser opened once despite duplicate showDocument"
grep -q 'openExternalBrowser' "$copilot_tmp/lsp.log" || fail "Copilot browser command executed in daemon"
login_again=$(env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" login) || fail "Copilot re-login"
grep -q '^already_signed_in=1$' <<<"$login_again" || fail "Copilot re-login short-circuits"
[[ $(grep -c '^signIn$' "$copilot_tmp/lsp.log") == 1 ]] || fail "Copilot signIn not duplicated"
env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" logout >/dev/null || fail "Copilot logout"

# No launcher is available to this daemon. Node and the fake LSP still run via
# Node's absolute path, independent of the deliberately empty PATH.
for browser_error in 0 1; do (
  no_browser_runtime="$repo_dir/.copilot-no-browser-test.$browser_error.$$"
  node_path=$(command -v node)
  mkdir -p "$copilot_tmp/no-browser-bin"
  no_browser_env=(
    "${copilot_env[@]}"
    LMLINE_COPILOT_RUNTIME_DIR="$no_browser_runtime"
    LMLINE_FAKE_COPILOT_LOG="$copilot_tmp/no-browser-$browser_error.log"
    LMLINE_FAKE_COPILOT_BROWSER_ERROR="$browser_error"
    LMLINE_COPILOT_OPEN_LOG=
    PATH="$copilot_tmp/no-browser-bin"
  )
  trap 'env "${no_browser_env[@]}" "$node_path" "$repo_dir/lmline/copilot-client.js" restart >/dev/null 2>&1 || true; rm -rf "$no_browser_runtime"' EXIT
  no_browser_login=$(env "${no_browser_env[@]}" "$node_path" "$repo_dir/lmline/copilot-client.js" login 2>"$copilot_tmp/no-browser.err") || fail "Copilot login without a browser is nonfatal"
  grep -q '^user_code=TEST-CODE$' <<<"$no_browser_login" || fail "Copilot device code without a browser"
  grep -q '^browser_opened=0$' <<<"$no_browser_login" || fail "Copilot missing launcher reports false"
  ! grep -q '^browser_opened=1$' <<<"$no_browser_login" || fail "Copilot missing launcher never reports success"
  grep -q 'could not launch the browser' "$copilot_tmp/no-browser.err" || fail "Copilot missing launcher diagnostic"
  grep -Fq 'visit: https://github.com/login/device?user_code=TEST-CODE' "$copilot_tmp/no-browser.err" || fail "Copilot manual device URL without a browser"
  copilot_wait_log '^showDocument-success=false$' "$copilot_tmp/no-browser-$browser_error.log" || fail "Copilot missing launcher reports LSP failure"
  if [[ "$browser_error" == 1 ]]; then
    grep -q 'browser command failed: fake browser command failed' "$copilot_tmp/no-browser.err" || fail "Copilot executeCommand failure is surfaced"
  fi
); done
cli_status=$(env "${copilot_env[@]}" "$repo_dir/lmline/lmline" copilot status) || fail "Copilot CLI status"
grep -q '^status=OK$' <<<"$cli_status" || fail "Copilot CLI status output"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete commands) || fail "Copilot command completion"
grep -q '^setup$' < <("$repo_dir/lmline/lmline" complete subcommands copilot) || fail "Copilot subcommand completion"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_REWRITE_BACKEND) || fail "Copilot backend completion"
grep -q 'copilot chatgpt' "$repo_dir/lmline/completions/lmline.bash" || fail "bash completion includes copilot"
grep -q 'setup update login status logout restart remove' "$repo_dir/lmline/completions/lmline.bash" || fail "bash completion copilot subcommands"
grep -q 'copilot chatgpt' "$repo_dir/lmline/completions/_lmline" || fail "zsh completion includes copilot"
grep -q 'setup update login status logout restart remove' "$repo_dir/lmline/completions/_lmline" || fail "zsh completion copilot subcommands"

annotated=$(env "${copilot_env[@]}" bash -c '
  source "$1/config.bash"
  LMLINE_CONFIG_DIR=$2
  __lmline_init_dirs "$1"
  source "$1/policy.bash"
  source "$1/actions.bash"
  __lmline_copilot_candidates "echo 😀 old" 10 bash
' _ "$repo_dir/lmline" "$copilot_tmp/config") || fail "Copilot candidate bridge"
grep -q '^lmline-candidate: low' <<<"$annotated" || fail "Copilot candidate risk annotation"
grep -q $'\techo 😀 new$' <<<"$annotated" || fail "Copilot candidate protocol"
! grep -q 'definitely-not-a-real-lmline-command' <<<"$annotated" || fail "unavailable Copilot command rejected"
copilot_wait_log '^textDocument/didShowCompletion$' "$copilot_tmp/lsp.log" || {
  tail -n 40 "$copilot_tmp/lsp.log" >&2 || true
  fail "Copilot show notification arrives"
}
copilot_wait_log '^textDocument/didClose$' "$copilot_tmp/lsp.log" || {
  tail -n 40 "$copilot_tmp/lsp.log" >&2 || true
  fail "Copilot close notification arrives"
}
show_line=$(grep -n -m1 '^textDocument/didShowCompletion$' "$copilot_tmp/lsp.log" | cut -d: -f1 || true)
close_line=$(grep -n -m1 '^textDocument/didClose$' "$copilot_tmp/lsp.log" | cut -d: -f1 || true)
[[ -n "$show_line" && -n "$close_line" && "$show_line" -lt "$close_line" ]] || fail "Copilot show notification precedes close"
grep -q '^didFocus-uri=yes$' "$copilot_tmp/lsp.log" || fail "Copilot didFocus carries a top-level uri"

# A killed LSP must be replaced in the existing daemon, not take it down.
(
  recovery_runtime="$repo_dir/.copilot-recovery-test.$$"
  recovery_env=(
    "${copilot_env[@]}"
    LMLINE_COPILOT_RUNTIME_DIR="$recovery_runtime"
    LMLINE_FAKE_COPILOT_LOG="$copilot_tmp/recovery-lsp.log"
    LMLINE_FAKE_COPILOT_PID_FILE="$copilot_tmp/recovery-lsp.pid"
  )
  trap 'env "${recovery_env[@]}" node "$repo_dir/lmline/copilot-client.js" restart >/dev/null 2>&1 || true; rm -rf "$recovery_runtime"' EXIT
  before_kill=$(env "${recovery_env[@]}" node "$repo_dir/lmline/copilot-client.js" edit 'echo 😀 old' 10 "$repo_dir") || fail "Copilot edit before child death"
  grep -q $'\techo 😀 new$' <<<"$before_kill" || fail "Copilot candidate before child death"
  before_token=${before_kill%%$'\t'*}
  [[ -n "$before_token" ]] || fail "Copilot candidate has an acceptance token"
  daemon_pid=$(cat "$recovery_runtime/daemon.pid")
  lsp_pid=$(cat "$copilot_tmp/recovery-lsp.pid")
  kill -KILL "$lsp_pid" || fail "kill Copilot LSP child"
  # Wait for the daemon to reap the child; the next edit is not an in-flight
  # request and must initialize a fresh server even for a signal-only exit.
  for ((i = 0; i < 100; i++)); do
    kill -0 "$lsp_pid" 2>/dev/null || break
    sleep 0.1
  done
  ! kill -0 "$lsp_pid" 2>/dev/null || fail "Copilot LSP child exited"
  accept_after_kill=$(env "${recovery_env[@]}" node "$repo_dir/lmline/copilot-client.js" accept "$before_token") || fail "Copilot acceptance after child death"
  [[ "$accept_after_kill" == ok ]] || fail "Copilot acceptance response after child death"
  grep -q '^github.copilot.didAcceptCompletionItem$' "$copilot_tmp/recovery-lsp.log" || fail "Copilot acceptance forwarded after child death"
  after_kill=$(env "${recovery_env[@]}" node "$repo_dir/lmline/copilot-client.js" edit 'echo 😀 old' 10 "$repo_dir") || {
    sed -n '1,80p' "$recovery_runtime/daemon.log" >&2 || true
    fail "Copilot edit recovers after child death"
  }
  grep -q $'\techo 😀 new$' <<<"$after_kill" || fail "Copilot candidate after child death"
  [[ $(cat "$copilot_tmp/recovery-lsp.pid") != "$lsp_pid" ]] || fail "Copilot starts a new LSP child"
  [[ $(cat "$recovery_runtime/daemon.pid") == "$daemon_pid" ]] || fail "Copilot preserves daemon after child death"
  kill -0 "$daemon_pid" || fail "Copilot daemon stays alive"
  ! grep -Eqi 'unhandled|throw er;' "$recovery_runtime/daemon.log" || fail "Copilot daemon has no unhandled pipe error"
  [[ $(grep -c '^initialize$' "$copilot_tmp/recovery-lsp.log") == 2 ]] || fail "Copilot initializes replacement child"
  [[ $(grep -c '^workspace/didChangeWorkspaceFolders$' "$copilot_tmp/recovery-lsp.log") == 2 ]] || fail "Copilot restores workspace for replacement child"
)

empty_rt="$copilot_tmp/empty-run"
mkdir -p "$empty_rt"
empty_out=$(env "${copilot_env[@]}" LMLINE_COPILOT_RUNTIME_DIR="$empty_rt" LMLINE_FAKE_COPILOT_EMPTY=1 \
  node "$repo_dir/lmline/copilot-client.js" edit 'echo x' 6 "$repo_dir" 2>&1) || fail "Copilot empty-result edit"
grep -q 'no candidates from Copilot' <<<"$empty_out" || fail "Copilot empty-result diagnostic"
env "${copilot_env[@]}" LMLINE_COPILOT_RUNTIME_DIR="$empty_rt" node "$repo_dir/lmline/copilot-client.js" restart >/dev/null 2>&1 || true

generate_annotated=$(env "${copilot_env[@]}" bash -c '
  source "$1/config.bash"
  LMLINE_CONFIG_DIR=$2
  __lmline_init_dirs "$1"
  source "$1/policy.bash"
  source "$1/actions.bash"
  __lmline_copilot_candidates "echo hi " 8 bash generate
' _ "$repo_dir/lmline" "$copilot_tmp/config") || fail "Copilot generate bridge"
grep -q $'\techo hi there$' <<<"$generate_annotated" || fail "Copilot generate insertion"
grep -q $'\techo hi everyone$' <<<"$generate_annotated" || fail "Copilot generate range edit"
grep -q $'\techo hi comrade$' <<<"$generate_annotated" || fail "Copilot generate command item"
! grep -q 'bad' <<<"$generate_annotated" || fail "Copilot generate multiline rejected"
grep -q '^textDocument/didShowCompletion$' "$copilot_tmp/lsp.log" || fail "Copilot generate show notification"

fix_out=$(env "${copilot_env[@]}" LMLINE_FIX_BACKEND=copilot bash -c '
  source "$1/config.bash"
  LMLINE_CONFIG_DIR=$2
  source "$1/context.bash"
  source "$1/policy.bash"
  source "$1/actions.bash"
  __lmline_fix_run "false" bash 5 "$1/engine" 3 "" 2>/dev/null
' _ "$repo_dir/lmline" "$copilot_tmp/config") || fail "Copilot fix run"
grep -q $'\ttrue$' <<<"$fix_out" || fail "Copilot fix candidate"
grep -q '^didOpen-context=yes$' "$copilot_tmp/lsp.log" || fail "Copilot fix execution context"

grep -q '^engine$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_GENERATE_BACKEND) || fail "Generate backend completion"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_GENERATE_BACKEND) || fail "Generate backend completion"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_FIX_BACKEND) || fail "Fix backend completion"

hint_out=$(LMLINE_CONFIG_DIR="$copilot_tmp/hint-config" "$repo_dir/lmline/lmline" config set LMLINE_REWRITE_BACKEND copilot 2>&1) || fail "Copilot config set"
grep -q 'Copilot enabled for LMLINE_REWRITE_BACKEND' <<<"$hint_out" || fail "Copilot config set hint"

for shell_name in zsh bash; do
  reload_cfg="$copilot_tmp/reload-$shell_name"
  mkdir -p "$reload_cfg"
  if [[ "$shell_name" == bash ]]; then
    env "${copilot_env[@]}" LMLINE_CONFIG_DIR="$reload_cfg" bash --norc -i -c '
      source "$1/lmline/init.bash"
      [[ "${LMLINE_REWRITE_BACKEND:-engine}" == engine ]] || exit 9
      "$2/lmline" config set LMLINE_REWRITE_BACKEND copilot >/dev/null 2>&1
      READLINE_LINE="echo 😀 old"
      READLINE_POINT=10
      __lmline_rewrite_widget
      [[ "$READLINE_LINE" == "echo 😀 new" ]]
    ' _ "$repo_dir" "$repo_dir/lmline" || fail "Bash Copilot config auto-reload"
  elif command -v zsh >/dev/null 2>&1; then
    env "${copilot_env[@]}" LMLINE_CONFIG_DIR="$reload_cfg" zsh -fic '
      source "$1/lmline/init.zsh"
      [[ "${LMLINE_REWRITE_BACKEND:-engine}" == engine ]] || exit 9
      "$2/lmline" config set LMLINE_REWRITE_BACKEND copilot >/dev/null 2>&1
      BUFFER="echo 😀 old"
      CURSOR=10
      lmline-zsh-rewrite-widget
      [[ "$BUFFER" == "echo 😀 new" ]]
    ' _ "$repo_dir" "$repo_dir/lmline" || fail "zsh Copilot config auto-reload"
  fi
done

# Same-second settings rewrites must reload without sleeping: the mtime is
# forced equal so only content identity can notice the change.
samesec_bash_cfg="$copilot_tmp/reload-samesec-bash"
mkdir -p "$samesec_bash_cfg"
LMLINE_CONFIG_DIR="$samesec_bash_cfg" "$repo_dir/lmline/lmline" config set LMLINE_TOOL_COMMAND_RUN 1 >/dev/null
cp "$samesec_bash_cfg/settings.bash" "$samesec_bash_cfg/settings.v1"
LMLINE_CONFIG_DIR="$samesec_bash_cfg" bash --norc -c '
  source "$1/lmline/config.bash"
  __lmline_reload_settings_if_changed "$2"
  [[ "${LMLINE_TOOL_COMMAND_RUN:-}" == 1 ]] || exit 9
  "$3/lmline" config set LMLINE_TOOL_COMMAND_RUN 0 >/dev/null 2>&1
  touch -r "$2/settings.v1" "$2/settings.bash"
  __lmline_reload_settings_if_changed "$2"
  [[ "${LMLINE_TOOL_COMMAND_RUN:-}" == 0 ]]
' _ "$repo_dir" "$samesec_bash_cfg" "$repo_dir/lmline" || fail "Bash same-second config reload"
if command -v zsh >/dev/null 2>&1; then
  samesec_zsh_cfg="$copilot_tmp/reload-samesec-zsh"
  mkdir -p "$samesec_zsh_cfg"
  LMLINE_CONFIG_DIR="$samesec_zsh_cfg" "$repo_dir/lmline/lmline" config set LMLINE_TOOL_COMMAND_RUN 1 >/dev/null
  cp "$samesec_zsh_cfg/settings.bash" "$samesec_zsh_cfg/settings.v1"
  LMLINE_CONFIG_DIR="$samesec_zsh_cfg" zsh -fic '
    source "$1/lmline/init.zsh"
    [[ "${LMLINE_TOOL_COMMAND_RUN:-}" == 1 ]] || exit 9
    "$3/lmline" config set LMLINE_TOOL_COMMAND_RUN 0 >/dev/null 2>&1
    touch -r "$2/settings.v1" "$2/settings.bash"
    __lmline_zsh_reload_settings_if_changed
    [[ "${LMLINE_TOOL_COMMAND_RUN:-}" == 0 ]]
  ' _ "$repo_dir" "$samesec_zsh_cfg" "$repo_dir/lmline" || fail "zsh same-second config reload"
fi

env "${copilot_env[@]}" LMLINE_REWRITE_BACKEND=copilot LMLINE_ASYNC=0 bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="echo 😀 old"
  READLINE_POINT=10
  __lmline_rewrite_widget
  [[ "$READLINE_LINE" == "echo 😀 new" ]]
' _ "$repo_dir" || fail "Bash Copilot rewrite widget"

env "${copilot_env[@]}" LMLINE_GENERATE_BACKEND=copilot LMLINE_ASYNC=0 bash --norc -i -c '
  source "$1/lmline/init.bash"
  READLINE_LINE="echo hi "
  READLINE_POINT=8
  __lmline_generate_widget
  [[ "$READLINE_LINE" == "echo hi there" ]]
' _ "$repo_dir" || fail "Bash Copilot generate widget"

if command -v zsh >/dev/null 2>&1; then
  env "${copilot_env[@]}" LMLINE_REWRITE_BACKEND=copilot LMLINE_ASYNC=0 zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="echo 😀 old"
    CURSOR=10
    lmline-zsh-rewrite-widget
    [[ "$BUFFER" == "echo 😀 new" ]]
  ' _ "$repo_dir" || fail "zsh Copilot rewrite widget"
  env "${copilot_env[@]}" LMLINE_GENERATE_BACKEND=copilot LMLINE_ASYNC=0 zsh -fic '
    source "$1/lmline/init.zsh"
    BUFFER="echo hi "
    CURSOR=8
    lmline-zsh-generate-widget
    [[ "$BUFFER" == "echo hi there" ]]
  ' _ "$repo_dir" || fail "zsh Copilot generate widget"
fi

fake_bin="$copilot_tmp/bin"
mkdir -p "$fake_bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$LMLINE_FAKE_NPM_LOG"\n' >"$fake_bin/npm"
chmod +x "$fake_bin/npm"
PATH="$fake_bin:$PATH" LMLINE_FAKE_NPM_LOG="$copilot_tmp/npm.log" LMLINE_CONFIG_DIR="$copilot_tmp/setup-config" \
  "$repo_dir/lmline/lmline" copilot setup >/dev/null || fail "Copilot setup"
grep -q '@github/copilot-language-server@1.498.0' "$copilot_tmp/npm.log" || fail "Copilot pinned setup version"
PATH="$fake_bin:$PATH" LMLINE_FAKE_NPM_LOG="$copilot_tmp/npm.log" LMLINE_CONFIG_DIR="$copilot_tmp/setup-config" \
  "$repo_dir/lmline/lmline" copilot update 1.499.0 >/dev/null || fail "Copilot explicit update"
grep -q '@github/copilot-language-server@1.499.0' "$copilot_tmp/npm.log" || fail "Copilot update version"

# The bundled producer emits a lone `copilot:<token>` flags field. The
# shell-side accept handoff must forward the bare token, not the marker,
# whether the marker stands first or follows another marker, while a token
# that merely carries the word stays whole-marker negative.
copilot_handoff_log="$copilot_tmp/accept-handoff.log"
: > "$copilot_handoff_log"
LMLINE_ACCEPT_LOG="$copilot_handoff_log" bash -c '
  source "$1/lmline/config.bash"
  LMLINE_CONFIG_DIR="$2"
  __lmline_init_dirs "$1/lmline" >/dev/null 2>&1
  source "$1/lmline/policy.bash"
  source "$1/lmline/actions.bash"
  node() { printf "%s\n" "$*" >>"$LMLINE_ACCEPT_LOG"; }
  disown() { return 0; }
  __lmline_copilot_accept "copilot:bare-token-1"
  wait 2>/dev/null || true; sleep 0.3
  __lmline_copilot_accept "other,copilot:bare-token-2"
  wait 2>/dev/null || true; sleep 0.3
  __lmline_copilot_accept "copilot:bare-token-3,other"
  wait 2>/dev/null || true; sleep 0.3
  __lmline_copilot_accept "xcopilot:fake"
  wait 2>/dev/null || true; sleep 0.3
' _ "$repo_dir" "$copilot_tmp/config" || fail "Copilot accept handoff runs"
grep -q "accept bare-token-1$" "$copilot_handoff_log" || fail "Copilot first-marker token is bare"
grep -q "accept bare-token-2$" "$copilot_handoff_log" || fail "Copilot later-marker token is bare"
grep -q "accept bare-token-3$" "$copilot_handoff_log" || fail "Copilot leading-marker token is bare"
! grep -q "accept copilot:" "$copilot_handoff_log" || fail "Copilot accept carries no marker"
[[ $(wc -l <"$copilot_handoff_log" | tr -d " ") == 3 ]] || fail "Copilot whole-marker negative sends nothing"
if command -v zsh >/dev/null 2>&1; then
  copilot_zhandoff_log="$copilot_tmp/accept-zhandoff.log"
  : > "$copilot_zhandoff_log"
  mkdir -p "$copilot_tmp/zhandoff-history"
  LMLINE_ACCEPT_LOG="$copilot_zhandoff_log" LMLINE_ZHISTORY="$copilot_tmp/zhandoff-history" env LMLINE_ACCEPT_LOG="$copilot_zhandoff_log" LMLINE_ZHISTORY="$copilot_tmp/zhandoff-history" zsh -f -i -c '
    export LMLINE_ACCEPT_LOG
    LMLINE_HISTORY_DIR="$LMLINE_ZHISTORY"
    source "$1/lmline/init.zsh"
    node() { printf "%s\n" "$*" >>"$LMLINE_ACCEPT_LOG"; }
    __lmline_zsh_hint() { return 0; }
    __lmline_zsh_clear_hint() { return 0; }
    __lmline_zsh_record_suggestion() { return 0; }
    __LMLINE_ZSH_CANDIDATES=("echo one")
    __LMLINE_ZSH_RISKS=("low")
    __LMLINE_ZSH_REASONS=("no matching risk rule")
    __LMLINE_ZSH_FLAGS=("copilot:bare-ztoken-1")
    __LMLINE_ZSH_LAST_MODE="generate"
    __LMLINE_ZSH_LAST_ORIGINAL="# req"
    __lmline_zsh_apply_index 1
    sleep 0.5
  ' _ "$repo_dir" || fail "Copilot zsh accept handoff runs"
  grep -q "accept bare-ztoken-1$" "$copilot_zhandoff_log" || fail "Copilot zsh first-marker token is bare"
  ! grep -q "accept copilot:" "$copilot_zhandoff_log" || fail "Copilot zsh accept carries no marker"
fi

ok "Copilot Language Server integration"
