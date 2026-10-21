#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the subscription token wrapper keeps the status of an interrupted
# client, so an interrupt is not reported as a broken sign-in.

wrapper_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-chatgpt-wrapper.XXXXXX")
trap 'rm -rf "$wrapper_tmp"' EXIT

# A client that ends on a signal, the way the real one does.
cat >"$wrapper_tmp/client.js" <<'CLIENT'
#!/usr/bin/env node
process.exit(130);
CLIENT
chmod +x "$wrapper_tmp/client.js"

# The wrapper keeps the client's error file in the engine's work directory.
work_dir="$wrapper_tmp/work"
mkdir -p "$work_dir"
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
