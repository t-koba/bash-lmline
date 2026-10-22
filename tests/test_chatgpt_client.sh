#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the ChatGPT sign-in, token refresh, revocation and credential storage
# stay correct offline against the mock authorization server.

chatgpt_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-chatgpt-test.XXXXXX")
chatgpt_mock_pid=""
mock_base=""
credentials_file="$chatgpt_tmp/credentials.json"
host_id_file="$chatgpt_tmp/host-id"
browser_script="$chatgpt_tmp/browser.sh"

cleanup() {
  stop_mock
  rm -rf "$chatgpt_tmp"
}
trap cleanup EXIT

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

json_field() {
  node -e '
const fs = require("fs");
const credential = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const value = credential[process.argv[2]];
process.stdout.write(value === undefined || value === null ? "" : String(value));
' "$1" "$2"
}

# Marks the stored access token as expired without touching anything else.
expire_credential() {
  node -e '
const fs = require("fs");
const file = process.argv[1];
const credential = JSON.parse(fs.readFileSync(file, "utf8"));
credential.expires_at = Math.floor(Date.now() / 1000) - 30;
fs.writeFileSync(file, JSON.stringify(credential, null, 2) + "\n");
' "$1"
}

stop_mock() {
  if [[ -n "$chatgpt_mock_pid" ]]; then
    kill "$chatgpt_mock_pid" 2>/dev/null || true
    wait "$chatgpt_mock_pid" 2>/dev/null || true
    chatgpt_mock_pid=""
  fi
}

start_mock() {
  local mode=$1 log=$2 delay=${3-400}
  local out_file="$chatgpt_tmp/mock-server.out"
  stop_mock
  : >"$out_file"
  LMLINE_FAKE_AUTH_MODE="$mode" LMLINE_FAKE_CHATGPT_LOG="$log" LMLINE_FAKE_AUTH_DELAY_MS="$delay" \
    node "$repo_dir/tests/fake_chatgpt_auth.js" >"$out_file" 2>&1 &
  chatgpt_mock_pid=$!
  local i
  for ((i = 0; i < 200; i++)); do
    grep -q '^port=' "$out_file" 2>/dev/null && break
    sleep 0.05
  done
  grep -q '^port=' "$out_file" || {
    cat "$out_file" >&2
    fail "the mock authorization server did not start"
  }
  mock_base="http://127.0.0.1:$(sed -n 's/^port=//p' "$out_file" | head -n 1)"
}

client() {
  env LMLINE_CONFIG_DIR="$chatgpt_tmp/config" \
    LMLINE_CHATGPT_AUTH_URL="$mock_base" \
    LMLINE_CHATGPT_CREDENTIALS_FILE="$credentials_file" \
    LMLINE_CHATGPT_HOST_ID_FILE="$host_id_file" \
    LMLINE_CHATGPT_BROWSER_COMMAND="$browser_script" \
    LMLINE_CHATGPT_TIMEOUT=20 \
    node "$repo_dir/lmline/chatgpt-client.js" "$@"
}

cat >"$browser_script" <<'BROWSER'
#!/usr/bin/env bash
exec curl -sS -L --max-time 20 -- "$1" >/dev/null 2>&1
BROWSER
chmod +x "$browser_script"

# 1. Without a session the status names the next action.
credentials_file="$chatgpt_tmp/credentials-absent.json"
status_out=$(client status) || fail "ChatGPT status without a session"
grep -q '^status=not-signed-in$' <<<"$status_out" || fail "ChatGPT status without a session"
grep -q '^registered=0$' <<<"$status_out" || fail "ChatGPT status without a session has no registration"
grep -q '^next=lmline\\ chatgpt\\ login$' <<<"$status_out" || fail "ChatGPT status hints the next action"
ok "ChatGPT status without a session hints the next action"

# 2. Login succeeds, stores the issued client id and keeps the file private.
credentials_file="$chatgpt_tmp/credentials-login.json"
start_mock "" "$chatgpt_tmp/mock-login.log"
login_out=$(client login 2>"$chatgpt_tmp/login.err") || {
  cat "$chatgpt_tmp/login.err" >&2
  fail "ChatGPT login"
}
grep -q '^status=ok$' <<<"$login_out" || fail "ChatGPT login status"
grep -q '^authorize_url=http://' <<<"$login_out" || fail "ChatGPT login prints the authorize URL"
grep -q '^plan_usage=enabled$' <<<"$login_out" || fail "ChatGPT login plan usage"
grep -q '^client_id=oaiapp_mock_client$' <<<"$login_out" || fail "ChatGPT login issued client id"
grep -q '^registered=1$' <<<"$login_out" || fail "ChatGPT login registration flag"
grep -q '^registration=created$' <<<"$login_out" || fail "ChatGPT login registration kind"
grep -q '^account=lmline.mock@example.invalid$' <<<"$login_out" || fail "ChatGPT login account"
[[ -f "$credentials_file" ]] || fail "ChatGPT credential file"
[[ "$(file_mode "$credentials_file")" == "600" ]] || fail "ChatGPT credential file mode is 0600"
[[ "$(file_mode "$host_id_file")" == "600" ]] || fail "ChatGPT host id file mode is 0600"
grep -q '"client_id": "oaiapp_mock_client"' "$credentials_file" || fail "ChatGPT issued client id saved"
grep -q '^authorize_client_id=dynamic_agent_client$' "$chatgpt_tmp/mock-login.log" || fail "ChatGPT first registration uses the dynamic client id"
grep -q '^authorize_agent_name_hint=lmline$' "$chatgpt_tmp/mock-login.log" || fail "ChatGPT first registration sends the agent name hint"
grep -q '^authorize_code_challenge_method=S256$' "$chatgpt_tmp/mock-login.log" || fail "ChatGPT uses PKCE"
grep -q '^token_client_id=oaiapp_mock_client$' "$chatgpt_tmp/mock-login.log" || fail "ChatGPT token exchange uses the issued client id"
ok "ChatGPT login stores the issued client id"

# 3. The status output never contains a token.
access_token=$(json_field "$credentials_file" access_token)
refresh_token=$(json_field "$credentials_file" refresh_token)
id_token=$(json_field "$credentials_file" id_token)
status_out=$(client status) || fail "ChatGPT status"
grep -q '^status=signed-in$' <<<"$status_out" || fail "ChatGPT status value"
! grep -Fq "$access_token" <<<"$status_out" || fail "ChatGPT status hides the access token"
! grep -Fq "$refresh_token" <<<"$status_out" || fail "ChatGPT status hides the refresh token"
! grep -Fq "$id_token" <<<"$status_out" || fail "ChatGPT status hides the ID token"
ok "ChatGPT status hides every token"

# 4. A sign-in without the plan scope keeps the session but disables plan usage.
credentials_file="$chatgpt_tmp/credentials-no-plan.json"
start_mock "no_plan_scope" "$chatgpt_tmp/mock-no-plan.log"
login_out=$(client login 2>"$chatgpt_tmp/no-plan.err") || {
  cat "$chatgpt_tmp/no-plan.err" >&2
  fail "ChatGPT login without the plan scope"
}
grep -q '^status=ok$' <<<"$login_out" || fail "ChatGPT login without the plan scope keeps the sign-in"
grep -q '^plan_usage=disabled$' <<<"$login_out" || fail "ChatGPT login reports disabled plan usage"
! grep -q '^scopes=.*chatgpt.tokens.use.direct' <<<"$login_out" || fail "ChatGPT login does not claim the plan scope"
[[ -f "$credentials_file" ]] || fail "ChatGPT keeps the credential file without the plan scope"
ok "ChatGPT reports disabled plan usage without the plan scope"

# 5. A denied sign-in stops before any code is exchanged.
credentials_file="$chatgpt_tmp/credentials-denied.json"
start_mock "deny" "$chatgpt_tmp/mock-deny.log"
if client login >"$chatgpt_tmp/deny.out" 2>"$chatgpt_tmp/deny.err"; then
  fail "ChatGPT login fails when the plan use is denied"
fi
grep -q 'plan use was not granted' "$chatgpt_tmp/deny.err" || fail "ChatGPT reports the denied plan use"
! grep -q '^token_grant_type=' "$chatgpt_tmp/mock-deny.log" || fail "ChatGPT exchanges no code after a denial"
[[ ! -f "$credentials_file" ]] || fail "ChatGPT stores no credential after a denial"
ok "ChatGPT stops a denied sign-in before the token exchange"

# 6. An expired access token is refreshed before it is handed out.
credentials_file="$chatgpt_tmp/credentials-expired.json"
start_mock "" "$chatgpt_tmp/mock-expired.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the token refresh"
expire_credential "$credentials_file"
stale_token=$(json_field "$credentials_file" access_token)
token_out=$(client token) || fail "ChatGPT token refresh"
[[ "$token_out" != "$stale_token" ]] || fail "ChatGPT token was refreshed"
[[ "$(json_field "$credentials_file" access_token)" == "$token_out" ]] || fail "ChatGPT stored the refreshed token"
[[ "$(wc -l <<<"$token_out" | tr -d ' ')" == "1" ]] || fail "ChatGPT token prints a single line"
(( $(json_field "$credentials_file" expires_at) > $(date +%s) )) || fail "ChatGPT stored the refreshed expiry"
ok "ChatGPT refreshes an expired access token"

# 7. A failing refresh is reported and never silently used as a fresh token.
credentials_file="$chatgpt_tmp/credentials-refresh-error.json"
start_mock "refresh_error" "$chatgpt_tmp/mock-refresh-error.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the refresh failure"
expire_credential "$credentials_file"
stale_token=$(json_field "$credentials_file" access_token)
if client refresh >"$chatgpt_tmp/refresh.out" 2>"$chatgpt_tmp/refresh.err"; then
  fail "ChatGPT refresh failure exits non-zero"
fi
grep -q 'lmline chatgpt login' "$chatgpt_tmp/refresh.err" || fail "ChatGPT refresh failure is actionable"
if client token >"$chatgpt_tmp/token.out" 2>"$chatgpt_tmp/token.err"; then
  fail "ChatGPT token refuses a stale credential"
fi
[[ ! -s "$chatgpt_tmp/token.out" ]] || fail "ChatGPT token prints no stale access token"
[[ "$(json_field "$credentials_file" access_token)" == "$stale_token" ]] || fail "ChatGPT keeps the stale credential marked as expired"
ok "ChatGPT reports a failing refresh"

# 8. Reauthorization reuses the issued client id instead of registering again.
credentials_file="$chatgpt_tmp/credentials-reauth.json"
start_mock "" "$chatgpt_tmp/mock-reauth.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the reauthorization"
reauth_out=$(client reauth 2>"$chatgpt_tmp/reauth.err") || {
  cat "$chatgpt_tmp/reauth.err" >&2
  fail "ChatGPT reauth"
}
grep -q '^status=ok$' <<<"$reauth_out" || fail "ChatGPT reauth status"
grep -q '^client_id=oaiapp_mock_client$' <<<"$reauth_out" || fail "ChatGPT reauth keeps the issued client id"
grep -q '^registration=reused$' <<<"$reauth_out" || fail "ChatGPT reauth reuses the registration"
grep -q '^authorize_client_id=oaiapp_mock_client$' "$chatgpt_tmp/mock-reauth.log" || fail "ChatGPT reauth sends the issued client id"
[[ "$(grep -c '^authorize_client_id=dynamic_agent_client$' "$chatgpt_tmp/mock-reauth.log")" == "1" ]] || fail "ChatGPT reauth creates no second registration"
grep -q '^authorize_agent_name_hint=$' "$chatgpt_tmp/mock-reauth.log" || fail "ChatGPT reauth omits the agent name hint"
grep -q '^authorize_id_token_hint=present$' "$chatgpt_tmp/mock-reauth.log" || fail "ChatGPT reauth sends the retained ID token"
ok "ChatGPT reauth reuses the issued client id"

# 9. Logout revokes the refresh token and clears the local tokens.
credentials_file="$chatgpt_tmp/credentials-logout.json"
start_mock "" "$chatgpt_tmp/mock-logout.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the logout"
logout_out=$(client logout 2>"$chatgpt_tmp/logout.err") || fail "ChatGPT logout"
grep -q '^status=logged-out$' <<<"$logout_out" || fail "ChatGPT logout status"
grep -q '^revoked=yes$' <<<"$logout_out" || fail "ChatGPT logout confirms the revocation"
grep -q '^revoke_client_id=oaiapp_mock_client$' "$chatgpt_tmp/mock-logout.log" || fail "ChatGPT revocation sends the issued client id"
[[ -z "$(json_field "$credentials_file" access_token)" ]] || fail "ChatGPT logout clears the access token"
[[ -z "$(json_field "$credentials_file" refresh_token)" ]] || fail "ChatGPT logout clears the refresh token"
[[ -z "$(json_field "$credentials_file" id_token)" ]] || fail "ChatGPT logout clears the ID token"
[[ "$(json_field "$credentials_file" client_id)" == "oaiapp_mock_client" ]] || fail "ChatGPT logout keeps the registration"
logout_status=$(client status) || fail "ChatGPT status after the logout"
grep -q '^status=signed-out$' <<<"$logout_status" || fail "ChatGPT status after the logout"
ok "ChatGPT logout revokes and clears the local tokens"

# 10. A failing revocation still clears the local tokens and says so.
credentials_file="$chatgpt_tmp/credentials-revoke-error.json"
start_mock "revoke_error" "$chatgpt_tmp/mock-revoke-error.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the failing revocation"
logout_out=$(client logout 2>"$chatgpt_tmp/logout.err") || fail "ChatGPT logout with a failing revocation"
grep -q '^status=logged-out$' <<<"$logout_out" || fail "ChatGPT logout status with a failing revocation"
grep -q '^revoked=no$' <<<"$logout_out" || fail "ChatGPT logout reports an unconfirmed revocation"
[[ -z "$(json_field "$credentials_file" access_token)" ]] || fail "ChatGPT clears the access token after a failing revocation"
[[ -z "$(json_field "$credentials_file" refresh_token)" ]] || fail "ChatGPT clears the refresh token after a failing revocation"
ok "ChatGPT logout reports an unconfirmed revocation"

# 11. A credential file that others can read is refused.
credentials_file="$chatgpt_tmp/credentials-mode.json"
start_mock "" "$chatgpt_tmp/mock-mode.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the permission check"
chmod 644 "$credentials_file"
if client status >"$chatgpt_tmp/mode.out" 2>"$chatgpt_tmp/mode.err"; then
  fail "ChatGPT refuses a credential file with a wide mode"
fi
grep -q 'chmod 600' "$chatgpt_tmp/mode.err" || fail "ChatGPT reports how to fix the credential file mode"
chmod 600 "$credentials_file"
status_out=$(client status) || fail "ChatGPT status after the permission fix"
grep -q '^status=signed-in$' <<<"$status_out" || fail "ChatGPT status after the permission fix"
ok "ChatGPT refuses a world readable credential file"

# 12. A session without the plan scope cannot be used for a paid request.
credentials_file="$chatgpt_tmp/credentials-no-plan-token.json"
start_mock "no_plan_scope" "$chatgpt_tmp/mock-no-plan-token.log"
client login >/dev/null 2>&1 || fail "ChatGPT login without the plan scope"
if client token >"$chatgpt_tmp/no-plan-token.out" 2>"$chatgpt_tmp/no-plan-token.err"; then
  fail "ChatGPT hands out a token without the plan scope"
fi
grep -q 'plan use was not granted' "$chatgpt_tmp/no-plan-token.err" || fail "ChatGPT reports the missing plan scope"
[[ ! -s "$chatgpt_tmp/no-plan-token.out" ]] || fail "ChatGPT prints a token without the plan scope"
ok "ChatGPT refuses a token without the plan scope"

# 13. A logout clears the plan grant of the revoked session.
credentials_file="$chatgpt_tmp/credentials-logout-scope.json"
start_mock "" "$chatgpt_tmp/mock-logout-scope.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the logout"
client logout >/dev/null 2>&1 || fail "ChatGPT logout"
logout_status=$(client status) || fail "ChatGPT status after the logout"
grep -q '^plan_usage=disabled$' <<<"$logout_status" || fail "ChatGPT status after the logout still claims plan usage"
grep -q '^scopes=$' <<<"$logout_status" || fail "ChatGPT status after the logout still lists the revoked scopes"
ok "ChatGPT logout clears the plan grant"

# 14. Two concurrent refreshes do not race the rotating refresh token: the
# second one waits for the lock and reuses the token the first one stored.
credentials_file="$chatgpt_tmp/credentials-concurrent.json"
start_mock "rotate_refresh" "$chatgpt_tmp/mock-concurrent.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the concurrent refresh"
expire_credential "$credentials_file"
client token >"$chatgpt_tmp/concurrent-1.out" 2>"$chatgpt_tmp/concurrent-1.err" &
concurrent_pid_1=$!
client token >"$chatgpt_tmp/concurrent-2.out" 2>"$chatgpt_tmp/concurrent-2.err" &
concurrent_pid_2=$!
concurrent_rc_1=0
concurrent_rc_2=0
wait "$concurrent_pid_1" || concurrent_rc_1=$?
wait "$concurrent_pid_2" || concurrent_rc_2=$?
[[ "$concurrent_rc_1" == 0 ]] || fail "the first concurrent token command failed: $(sed -n '1p' "$chatgpt_tmp/concurrent-1.err")"
[[ "$concurrent_rc_2" == 0 ]] || fail "the second concurrent token command failed: $(sed -n '1p' "$chatgpt_tmp/concurrent-2.err")"
concurrent_token_1=$(sed -n '1p' "$chatgpt_tmp/concurrent-1.out")
concurrent_token_2=$(sed -n '1p' "$chatgpt_tmp/concurrent-2.out")
[[ -n "$concurrent_token_1" && -n "$concurrent_token_2" ]] || fail "a concurrent token command printed no token"
[[ "$concurrent_token_1" == "$concurrent_token_2" ]] || fail "the concurrent token commands disagree"
ok "ChatGPT serializes concurrent token refreshes"

# 15. A live lock is never treated as stale: the second token command waits
# for the first one instead of refreshing the rotated token itself.
credentials_file="$chatgpt_tmp/credentials-heartbeat.json"
start_mock "rotate_refresh" "$chatgpt_tmp/mock-heartbeat.log" 2000
client login >/dev/null 2>&1 || fail "ChatGPT login before the live lock test"
expire_credential "$credentials_file"
export LMLINE_CHATGPT_LOCK_STALE_MS=1000
client token >"$chatgpt_tmp/heartbeat-1.out" 2>"$chatgpt_tmp/heartbeat-1.err" &
heartbeat_pid_1=$!
sleep 1.2
client token >"$chatgpt_tmp/heartbeat-2.out" 2>"$chatgpt_tmp/heartbeat-2.err" &
heartbeat_pid_2=$!
heartbeat_rc_1=0
heartbeat_rc_2=0
wait "$heartbeat_pid_1" || heartbeat_rc_1=$?
wait "$heartbeat_pid_2" || heartbeat_rc_2=$?
unset LMLINE_CHATGPT_LOCK_STALE_MS
[[ "$heartbeat_rc_1" == 0 ]] || fail "the first live-lock token command failed: $(sed -n '1p' "$chatgpt_tmp/heartbeat-1.err")"
[[ "$heartbeat_rc_2" == 0 ]] || fail "the second live-lock token command failed: $(sed -n '1p' "$chatgpt_tmp/heartbeat-2.err")"
[[ "$(sed -n '1p' "$chatgpt_tmp/heartbeat-1.out")" == "$(sed -n '1p' "$chatgpt_tmp/heartbeat-2.out")" ]] \
  || fail "the live-lock token commands disagree"
ok "ChatGPT keeps a live lock fresh"

# 16. A logout that overlaps a refresh leaves the session signed out.
credentials_file="$chatgpt_tmp/credentials-logout-race.json"
start_mock "rotate_refresh" "$chatgpt_tmp/mock-logout-race.log" 2000
client login >/dev/null 2>&1 || fail "ChatGPT login before the logout race"
expire_credential "$credentials_file"
client token >"$chatgpt_tmp/logout-race-token.out" 2>"$chatgpt_tmp/logout-race-token.err" &
logout_race_pid=$!
sleep 0.3
client logout >"$chatgpt_tmp/logout-race.out" 2>"$chatgpt_tmp/logout-race.err" \
  || fail "ChatGPT logout during a refresh"
logout_race_rc=0
wait "$logout_race_pid" || logout_race_rc=$?
logout_race_status=$(client status) || fail "ChatGPT status after the logout race"
grep -q '^status=signed-out$' <<<"$logout_race_status" || fail "the logout race left a signed-in session"
grep -q '^plan_usage=disabled$' <<<"$logout_race_status" || fail "the logout race left a plan grant"
grep -q '^scopes=$' <<<"$logout_race_status" || fail "the logout race left the revoked scopes"
ok "ChatGPT logout wins over an overlapping refresh"

# 17. A token answer that states no scope leaves the plan grant unproven.
credentials_file="$chatgpt_tmp/credentials-no-scope-refresh.json"
start_mock "no_scope_refresh" "$chatgpt_tmp/mock-no-scope-refresh.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the scope-less refresh"
expire_credential "$credentials_file"
if client refresh >"$chatgpt_tmp/no-scope-refresh.out" 2>"$chatgpt_tmp/no-scope-refresh.err"; then
  fail "ChatGPT keeps a plan grant the provider did not state"
fi
grep -q 'plan use was not granted' "$chatgpt_tmp/no-scope-refresh.err" \
  || fail "ChatGPT reports the unproven plan grant"
no_scope_status=$(client status) || fail "ChatGPT status after the scope-less refresh"
grep -q '^plan_usage=disabled$' <<<"$no_scope_status" || fail "ChatGPT keeps the plan grant after a scope-less refresh"
grep -q '^scopes=$' <<<"$no_scope_status" || fail "ChatGPT keeps the scopes after a scope-less refresh"
ok "ChatGPT drops a plan grant the provider did not state"

# 18. A signalled command releases the credential lock, so the next one runs.
credentials_file="$chatgpt_tmp/credentials-signalled.json"
start_mock "rotate_refresh" "$chatgpt_tmp/mock-signalled.log" 3000
client login >/dev/null 2>&1 || fail "ChatGPT login before the signalled lock test"
expire_credential "$credentials_file"
lock_file="$chatgpt_tmp/credentials.lock"
for signal_case in "INT 130" "HUP 129"; do
  signal_name=${signal_case%% *}
  expected_status=${signal_case##* }
  env LMLINE_CONFIG_DIR="$chatgpt_tmp/config" \
    LMLINE_CHATGPT_AUTH_URL="$mock_base" \
    LMLINE_CHATGPT_CREDENTIALS_FILE="$credentials_file" \
    LMLINE_CHATGPT_HOST_ID_FILE="$host_id_file" \
    LMLINE_CHATGPT_BROWSER_COMMAND="$browser_script" \
    LMLINE_CHATGPT_TIMEOUT=20 \
    node "$repo_dir/lmline/chatgpt-client.js" token \
    >"$chatgpt_tmp/signalled-$signal_name.out" 2>"$chatgpt_tmp/signalled-$signal_name.err" &
  signalled_pid=$!
  sleep 0.5
  kill -"$signal_name" "$signalled_pid" 2>/dev/null || true
  signalled_status=0
  wait "$signalled_pid" 2>/dev/null || signalled_status=$?
  [[ "$signalled_status" == "$expected_status" ]] \
    || fail "a $signal_name signalled command reports the wrong exit status: $signalled_status"
  [[ ! -e "$lock_file" ]] || fail "a signalled command left the credential lock behind"
done
client token >"$chatgpt_tmp/signalled-2.out" 2>"$chatgpt_tmp/signalled-2.err" \
  || fail "the command after a signalled one fails: $(sed -n '1p' "$chatgpt_tmp/signalled-2.err")"
ok "ChatGPT releases the credential lock when the command is signalled"

# 19. A lock that a dead holder left behind is reclaimed: the wait budget
# outlives the stale threshold, so the waiter can remove it itself.
credentials_file="$chatgpt_tmp/credentials-reclaim.json"
start_mock "" "$chatgpt_tmp/mock-reclaim.log"
client login >/dev/null 2>&1 || fail "ChatGPT login before the reclaim test"
lock_file="$chatgpt_tmp/credentials.lock"
: >"$lock_file"
touch -t 200001010000 "$lock_file"
export LMLINE_CHATGPT_LOCK_STALE_MS=1000
export LMLINE_CHATGPT_LOCK_WAIT_MS=500
client token >"$chatgpt_tmp/reclaim.out" 2>"$chatgpt_tmp/reclaim.err" \
  || fail "the command does not reclaim an abandoned lock: $(sed -n '1p' "$chatgpt_tmp/reclaim.err")"
unset LMLINE_CHATGPT_LOCK_STALE_MS LMLINE_CHATGPT_LOCK_WAIT_MS
[[ ! -e "$lock_file" ]] || fail "the reclaimed lock is still on disk"
ok "ChatGPT reclaims an abandoned credential lock"

# 20. A sign-in that overlaps a refresh is not overwritten by it.
credentials_file="$chatgpt_tmp/credentials-signin-race.json"
start_mock "rotate_refresh" "$chatgpt_tmp/mock-signin-race.log" 2000
client login >/dev/null 2>&1 || fail "ChatGPT login before the sign-in race"
expire_credential "$credentials_file"
client token >"$chatgpt_tmp/signin-race-token.out" 2>"$chatgpt_tmp/signin-race-token.err" &
signin_race_pid=$!
sleep 0.3
client login >"$chatgpt_tmp/signin-race-login.out" 2>"$chatgpt_tmp/signin-race-login.err" \
  || fail "ChatGPT login during a refresh: $(sed -n '1p' "$chatgpt_tmp/signin-race-login.err")"
signin_race_rc=0
wait "$signin_race_pid" || signin_race_rc=$?
login_token=$(grep '^issued_token=authorization_code:' "$chatgpt_tmp/mock-signin-race.log" | tail -n 1 | cut -d: -f2)
stored_token=$(json_field "$credentials_file" access_token)
[[ -n "$login_token" ]] || fail "the sign-in race issued no sign-in token"
[[ "$stored_token" == "$login_token" ]] \
  || fail "the refresh overwrote the fresh sign-in: $stored_token"
ok "ChatGPT keeps a fresh sign-in over an overlapping refresh"

# 21. A malformed credential file is reported without echoing its contents.
malformed_marker="SYNTHETICLEAK"
credentials_file="$chatgpt_tmp/credentials-malformed.json"
printf '%s{"access_token": "x"' "$malformed_marker" >"$credentials_file"
chmod 600 "$credentials_file"
malformed_rc=0
client status >"$chatgpt_tmp/malformed.out" 2>"$chatgpt_tmp/malformed.err" || malformed_rc=$?
(( malformed_rc != 0 )) || fail "a malformed credential file was accepted"
grep -q 'is not valid JSON' "$chatgpt_tmp/malformed.err" \
  || fail "a malformed credential file is not reported as invalid JSON: $(sed -n '1p' "$chatgpt_tmp/malformed.err")"
if grep -q "$malformed_marker" "$chatgpt_tmp/malformed.out"; then
  fail "the malformed credential file leaked into stdout"
fi
if grep -q "$malformed_marker" "$chatgpt_tmp/malformed.err"; then
  fail "the malformed credential file leaked into stderr"
fi
ok "ChatGPT reports a malformed credential file without echoing its contents"
