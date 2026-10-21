#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the subscription token wrapper keeps the status of an interrupted
# client, so an interrupt is not reported as a broken sign-in, and it keeps
# the reason a sign-in failed whatever the environment carries.

wrapper_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-chatgpt-wrapper.XXXXXX")
trap 'rm -rf "$wrapper_tmp"' EXIT

# A client that ends on a signal, the way the real one does.
cat >"$wrapper_tmp/client.js" <<'CLIENT'
#!/usr/bin/env node
process.exit(130);
CLIENT
chmod +x "$wrapper_tmp/client.js"

# shellcheck source=lmline/chatgpt.bash
source "$repo_dir/lmline/chatgpt.bash"

# The route resolves the client, so the override names the client of this
# case.
export LMLINE_CHATGPT_CLIENT="$wrapper_tmp/client.js"
wrapper_status=0
__lmline_chatgpt_access_token "$wrapper_tmp/token" \
  >"$wrapper_tmp/out" 2>"$wrapper_tmp/err" || wrapper_status=$?
[[ "$wrapper_status" == 130 ]] || fail "the wrapper reports $wrapper_status for an interrupted client"
! grep -q 'auth failed' "$wrapper_tmp/err" || fail "the wrapper reports an interrupt as a failed sign-in"
[[ ! -s "$wrapper_tmp/token" ]] || fail "the wrapper keeps the token of an interrupted client"
ok "the ChatGPT token wrapper keeps the status of an interrupted client"

# A client that fails with a reason of its own.
cat >"$wrapper_tmp/failing-client.js" <<'CLIENT'
#!/usr/bin/env node
process.stderr.write("the session is not signed in\n");
process.exit(1);
CLIENT
chmod +x "$wrapper_tmp/failing-client.js"

# The place of the client's error file is the function's business: a name in
# the environment that only one caller defines must not divert the client's
# message, and must not hide it.
inherited_err=$(work_dir="$wrapper_tmp/no-such-dir" LMLINE_CHATGPT_CLIENT="$wrapper_tmp/failing-client.js" \
  bash -c 'source "$1/lmline/chatgpt.bash"; __lmline_chatgpt_access_token "$2"' \
  _ "$repo_dir" "$wrapper_tmp/inherited-token" 2>&1) || true
grep -q 'the session is not signed in' <<<"$inherited_err" \
  || fail "the sign-in reason is lost: $inherited_err"
! grep -q 'No such file or directory' <<<"$inherited_err" \
  || fail "the sign-in reads a name that only one caller defines: $inherited_err"
ok "the ChatGPT token wrapper keeps the client's reason whatever the environment carries"
