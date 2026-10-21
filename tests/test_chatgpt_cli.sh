#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the ChatGPT subscription authentication mode stays visible and
# selectable in the command line surface: endpoint registration, the active
# mode, the doctor report, and the help.

cli_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-chatgpt-cli-test.XXXXXX")
trap 'rm -rf "$cli_tmp"' EXIT
config_dir="$cli_tmp/config"

lmline() {
  LMLINE_CONFIG_DIR="$config_dir" "$repo_dir/lmline/lmline" "$@"
}

# The authentication mode of an endpoint, as the last column of its line.
endpoint_auth_mode() {
  awk -F '\t' -v name="$1" '$1 == name { print $NF }'
}

# 1. An endpoint registers the subscription authentication mode.
lmline endpoint add sub https://api.openai.com/v1 --auth-mode chatgpt >/dev/null || fail "endpoint add with the chatgpt auth mode"
[[ "$(endpoint_auth_mode sub <<<"$(lmline endpoint list)")" == chatgpt ]] || fail "endpoint list carries the chatgpt auth mode"
ok "endpoint registration carries the chatgpt auth mode"

# 2. An endpoint without the option keeps the API-key path.
lmline endpoint add plain https://api.example.invalid/v1 >/dev/null || fail "endpoint add without the chatgpt auth mode"
[[ "$(endpoint_auth_mode plain <<<"$(lmline endpoint list)")" == api-key ]] || fail "endpoint list keeps the api-key auth mode"
ok "endpoint registration keeps the api-key auth mode"

# 3. An unknown authentication mode is refused.
if lmline endpoint add bad https://api.example.invalid/v1 --auth-mode token >"$cli_tmp/bad.out" 2>"$cli_tmp/bad.err"; then
  fail "endpoint add accepts an unknown auth mode"
fi
grep -q 'invalid auth_mode' "$cli_tmp/bad.err" || fail "endpoint add reports an unknown auth mode"
ok "endpoint registration refuses an unknown auth mode"

# 4. Selecting the endpoint makes the subscription path the active one.
lmline model add sub gpt-5 >/dev/null || fail "model add"
lmline use sub gpt-5 >/dev/null || fail "use the chatgpt endpoint"
current_out=$(lmline current) || fail "current"
grep -q '^auth_mode=chatgpt$' <<<"$current_out" || fail "current shows the chatgpt auth mode"
grep -q '^endpoint=sub$' <<<"$current_out" || fail "current shows the selected endpoint"
ok "the current report shows the active auth mode"

# 5. Without a selected profile the active mode is the API-key path.
current_out=$(LMLINE_CONFIG_DIR="$cli_tmp/empty" "$repo_dir/lmline/lmline" current) || fail "current without a profile"
grep -q '^auth_mode=api-key$' <<<"$current_out" || fail "current shows the api-key auth mode by default"
ok "the current report defaults to the api-key auth mode"

# 6. The doctor report names the authentication path and the search state.
doctor_out=$(lmline doctor) || fail "doctor"
grep -q '^auth_mode=chatgpt$' <<<"$doctor_out" || fail "doctor shows the chatgpt auth mode"
grep -q '^enabled=0$' <<<"$doctor_out" || fail "doctor shows the web search state"
grep -q 'native web search needs LMLINE_API_FORMAT=responses' <<<"$doctor_out" || fail "doctor explains the search format requirement"
ok "the doctor report shows the authentication and search state"

# 7. The help and the completion list the ChatGPT commands.
help_out=$(lmline help chatgpt) || fail "help for the chatgpt commands"
grep -q '^usage: lmline chatgpt login' <<<"$help_out" || fail "help for the chatgpt commands"
subcommands_out=$(lmline complete subcommands chatgpt) || fail "completion lists the chatgpt subcommands"
grep -qx login <<<"$subcommands_out" || fail "completion lists the chatgpt subcommands"
commands_out=$(lmline complete commands) || fail "completion lists the chatgpt command"
grep -qx chatgpt <<<"$commands_out" || fail "completion lists the chatgpt command"
ok "the help and the completion list the chatgpt commands"

# 8. An endpoint line written before the auth mode column still loads.
legacy_dir="$cli_tmp/legacy"
mkdir -p "$legacy_dir"
printf 'legacy\thttps://api.example.invalid/v1\tAuthorization\tBearer\t\t0.2\t800\ttext\t\t\t\t\t\n' >"$legacy_dir/endpoints.tsv"
legacy_out=$(LMLINE_CONFIG_DIR="$legacy_dir" "$repo_dir/lmline/lmline" endpoint list) || fail "endpoint list with a legacy endpoint line"
grep -q $'^legacy\thttps://api.example.invalid/v1' <<<"$legacy_out" || fail "legacy endpoint line"
[[ "$(endpoint_auth_mode legacy <<<"$legacy_out")" == api-key ]] || fail "legacy endpoint line keeps the api-key auth mode"
ok "a legacy endpoint line keeps the api-key auth mode"

# The model catalog of a plan endpoint is read with the plan token, and its
# entries carry the plan slug as the model id.
plan_bin="$cli_tmp/plan-bin"
mkdir -p "$plan_bin"
cat >"$plan_bin/client" <<'CLIENT'
#!/usr/bin/env node
process.stdout.write('plan-token\n');
CLIENT
chmod +x "$plan_bin/client"
cat >"$plan_bin/curl" <<'CURL'
#!/usr/bin/env bash
header=
for arg in "$@"; do
  case "$arg" in
    @*) header=${arg#@} ;;
  esac
done
printf 'called\n' >>"${LMLINE_FAKE_CURL_LOG:?}"
if [[ -n "$header" && -r "$header" ]] && grep -q 'Bearer plan-token' "$header"; then
  printf '%s\n' '{"models":[{"slug":"gpt-plan-one","display_name":"Plan One","visibility":"list"},{"slug":"gpt-plan-hidden","display_name":"Hidden","visibility":"hidden"}]}'
  exit 0
fi
printf 'the catalog request carried no plan token\n' >&2
exit 22
CURL
chmod +x "$plan_bin/curl"
lmline endpoint add plan https://api.openai.com/v1 --auth-mode chatgpt \
  --models-jq '.models[] | select(.visibility == "list") | {id: .slug, name: .display_name}' >/dev/null \
  || fail "the plan endpoint registration"
PATH="$plan_bin:$PATH" LMLINE_FAKE_CURL_LOG="$cli_tmp/curl.log" LMLINE_CHATGPT_CLIENT="$plan_bin/client" \
  lmline model refresh plan >"$cli_tmp/plan-refresh.out" 2>"$cli_tmp/plan-refresh.err" \
  || fail "the plan model refresh: $(sed -n '1p' "$cli_tmp/plan-refresh.err")"
plan_models=$(lmline model list plan)
grep -q $'^plan\tgpt-plan-one\t' <<<"$plan_models" || fail "the plan model is missing: $plan_models"
grep -q $'\tresponses$' <<<"$plan_models" || fail "the plan model has no Responses format: $plan_models"
! grep -q 'gpt-plan-hidden' <<<"$plan_models" || fail "a model the account does not list is stored"
ok "the plan endpoint reads its account model catalog"

# The plan token spends the user's ChatGPT plan, so it must not travel to a
# host the ChatGPT route does not allow. A foreign host is refused before
# the token is fetched, and no request is made.
lmline endpoint add foreign http://foreign.example.invalid/v1 --auth-mode chatgpt >/dev/null \
  || fail "the foreign endpoint registration"
: >"$cli_tmp/curl.log"
if PATH="$plan_bin:$PATH" LMLINE_FAKE_CURL_LOG="$cli_tmp/curl.log" LMLINE_CHATGPT_CLIENT="$plan_bin/client" \
    lmline model refresh foreign >"$cli_tmp/foreign.out" 2>"$cli_tmp/foreign.err"; then
  fail "the plan model refresh accepted a foreign host"
fi
grep -q 'the ChatGPT subscription token is not sent to' "$cli_tmp/foreign.err" \
  || fail "the refused host has no reason: $(sed -n '1p' "$cli_tmp/foreign.err")"
[[ ! -s "$cli_tmp/curl.log" ]] || fail "the plan token was sent to a foreign host"
ok "the plan model refresh keeps the token on an allowed host"

# A catalog URL on a foreign host is refused as well.
lmline endpoint add foreign-catalog https://api.openai.com/v1 --auth-mode chatgpt \
  --models-url https://foreign.example.invalid/models >/dev/null \
  || fail "the foreign catalog registration"
: >"$cli_tmp/curl.log"
if PATH="$plan_bin:$PATH" LMLINE_FAKE_CURL_LOG="$cli_tmp/curl.log" LMLINE_CHATGPT_CLIENT="$plan_bin/client" \
    lmline model refresh foreign-catalog >"$cli_tmp/foreign-catalog.out" 2>"$cli_tmp/foreign-catalog.err"; then
  fail "the plan model refresh accepted a foreign catalog host"
fi
grep -q 'the ChatGPT subscription token is not sent to' "$cli_tmp/foreign-catalog.err" \
  || fail "the refused catalog host has no reason: $(sed -n '1p' "$cli_tmp/foreign-catalog.err")"
[[ ! -s "$cli_tmp/curl.log" ]] || fail "the plan token was sent to a foreign catalog host"
ok "the plan model refresh keeps the token on an allowed catalog host"

# The client override reaches the commands of the route, so a catalog and a
# sign-in belong to the same client.
override_status=$(LMLINE_CHATGPT_CLIENT="$plan_bin/client" lmline chatgpt status 2>&1 || true)
grep -q 'plan-token' <<<"$override_status" \
  || fail "the chatgpt commands ignore the client override: $override_status"
ok "the chatgpt commands use the client override"

ok "chatgpt cli"
