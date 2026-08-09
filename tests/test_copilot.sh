#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

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
grep -q '^status=OK$' <<<"$login_out" || fail "Copilot login completion status"
grep -q '^user=fake-user$' <<<"$login_out" || fail "Copilot login user"
[[ $(wc -l <"$copilot_tmp/open.log" | tr -d ' ') == 1 ]] || fail "Copilot browser opened once despite duplicate showDocument"
grep -q 'openExternalBrowser' "$copilot_tmp/lsp.log" || fail "Copilot browser command executed in daemon"
login_again=$(env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" login) || fail "Copilot re-login"
grep -q '^already_signed_in=1$' <<<"$login_again" || fail "Copilot re-login short-circuits"
[[ $(grep -c '^signIn$' "$copilot_tmp/lsp.log") == 1 ]] || fail "Copilot signIn not duplicated"
env "${copilot_env[@]}" node "$repo_dir/lmline/copilot-client.js" logout >/dev/null || fail "Copilot logout"
cli_status=$(env "${copilot_env[@]}" "$repo_dir/lmline/lmline" copilot status) || fail "Copilot CLI status"
grep -q '^status=OK$' <<<"$cli_status" || fail "Copilot CLI status output"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete commands) || fail "Copilot command completion"
grep -q '^setup$' < <("$repo_dir/lmline/lmline" complete subcommands copilot) || fail "Copilot subcommand completion"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_REWRITE_BACKEND) || fail "Copilot backend completion"

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
show_line=$(grep -n -m1 '^textDocument/didShowInlineEdit$' "$copilot_tmp/lsp.log" | cut -d: -f1)
close_line=$(grep -n -m1 '^textDocument/didClose$' "$copilot_tmp/lsp.log" | cut -d: -f1)
[[ -n "$show_line" && -n "$close_line" && "$show_line" -lt "$close_line" ]] || fail "Copilot show notification precedes close"

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
  __lmline_fix_run "false" bash 5 "$repo_dir/lmline/engine" 3 "" 2>/dev/null
' _ "$repo_dir/lmline" "$copilot_tmp/config") || fail "Copilot fix run"
grep -q $'\ttrue$' <<<"$fix_out" || fail "Copilot fix candidate"
grep -q '^didOpen-context=yes$' "$copilot_tmp/lsp.log" || fail "Copilot fix execution context"

grep -q '^engine$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_GENERATE_BACKEND) || fail "Generate backend completion"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_GENERATE_BACKEND) || fail "Generate backend completion"
grep -q '^copilot$' < <("$repo_dir/lmline/lmline" complete setting-values LMLINE_FIX_BACKEND) || fail "Fix backend completion"

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

ok "Copilot Language Server integration"
