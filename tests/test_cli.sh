#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-config-test.XXXXXX")
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" endpoint add openai https://api.openai.com/v1 --auth-header Authorization --auth-scheme Bearer >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" endpoint set-secret openai redaction-sentinel >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" model add openai test-model >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" use openai test-model >/dev/null
config_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config get)
grep -q "LMLINE_BASE_URL=.*https://api.openai.com/v1" <<<"$config_out" || fail "endpoint use base url"
grep -q "LMLINE_MODEL=.*test-model" <<<"$config_out" || fail "endpoint use model"
grep -q "LMLINE_API_KEY_FILE=" <<<"$config_out" || fail "secret file reference"
! grep -q "redaction-sentinel" <<<"$config_out" || fail "secret redaction"
secret_file=$(grep "^export LMLINE_API_KEY_FILE=" "$cfg_tmp/config/settings.bash" | sed -E "s/^export LMLINE_API_KEY_FILE='?([^']*)'?$/\1/")
[[ -f "$secret_file" ]] || fail "secret file exists"
LMLINE_CONFIG_DIR="$cfg_tmp/config-local" "$repo_dir/lmline/lmline" endpoint add local http://127.0.0.1:8080/v1 >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-local" "$repo_dir/lmline/lmline" model add local local-model >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-local" "$repo_dir/lmline/lmline" use local local-model >/dev/null
local_config_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config-local" "$repo_dir/lmline/lmline" config get)
grep -q "LMLINE_BASE_URL=.*http://127.0.0.1:8080/v1" <<<"$local_config_out" || fail "local endpoint base url"
grep -q "LMLINE_MODEL=.*local-model" <<<"$local_config_out" || fail "local endpoint model"
LMLINE_CONFIG_DIR="$cfg_tmp/config-openrouter" "$repo_dir/lmline/lmline" endpoint add openrouter https://openrouter.ai/api/v1 >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-openrouter" "$repo_dir/lmline/lmline" model add openrouter openai/gpt-test >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-openrouter" "$repo_dir/lmline/lmline" use openrouter openai/gpt-test >/dev/null
openrouter_config_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config-openrouter" "$repo_dir/lmline/lmline" config get)
grep -q "LMLINE_BASE_URL=.*https://openrouter.ai/api/v1" <<<"$openrouter_config_out" || fail "openrouter endpoint base url"
LMLINE_CONFIG_DIR="$cfg_tmp/config-gemini" "$repo_dir/lmline/lmline" endpoint add gemini https://generativelanguage.googleapis.com/v1beta/openai >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-gemini" "$repo_dir/lmline/lmline" model add gemini gemini-2.5-flash >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-gemini" "$repo_dir/lmline/lmline" use gemini gemini-2.5-flash >/dev/null
gemini_config_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config-gemini" "$repo_dir/lmline/lmline" config get)
grep -q "LMLINE_BASE_URL=.*https://generativelanguage.googleapis.com/v1beta/openai" <<<"$gemini_config_out" || fail "gemini endpoint base url"
LMLINE_CONFIG_DIR="$cfg_tmp/config-sakura" "$repo_dir/lmline/lmline" endpoint add sakura https://api.ai.sakura.ad.jp/v1 --auth-header Authorization --auth-scheme Bearer >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-sakura" "$repo_dir/lmline/lmline" model add sakura gpt-oss-120b >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config-sakura" "$repo_dir/lmline/lmline" use sakura gpt-oss-120b >/dev/null
sakura_config_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config-sakura" "$repo_dir/lmline/lmline" config get)
grep -q "LMLINE_BASE_URL=.*https://api.ai.sakura.ad.jp/v1" <<<"$sakura_config_out" || fail "sakura endpoint base url"
grep -q "LMLINE_MODEL=.*gpt-oss-120b" <<<"$sakura_config_out" || fail "sakura endpoint model"
profiles_dir="$cfg_tmp/profiles"
mkdir -p "$profiles_dir"
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint add local http://127.0.0.1:1234/v1 --temperature 0.1 --max-tokens 600 --tool-mode text
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint add cloud https://llm.example/api --auth-header X-Api-Key --auth-scheme '' --tool-mode openai
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint set-secret cloud cloud-secret
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint add cloud https://llm.example/v2
endpoint_list=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint list)
grep -q $'^local\thttp://127.0.0.1:1234/v1' <<<"$endpoint_list" || fail "endpoint list local"
grep -q $'^cloud\thttps://llm.example/v2\tX-Api-Key\t\tconfigured' <<<"$endpoint_list" || fail "endpoint upsert preserves auth and secret"
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model add local local-test-model
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model add local local-test-model --temperature 0.3 --tool-mode auto
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model add cloud openai/gpt-test --max-tokens 700
model_list=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model list local)
grep -q $'^local\tlocal-test-model\t0.3\t\tauto$' <<<"$model_list" || fail "model add upsert"
complete_endpoints=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" complete endpoints)
grep -q '^local$' <<<"$complete_endpoints" || fail "complete endpoints"
complete_models=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" complete models cloud)
grep -q '^openai/gpt-test$' <<<"$complete_models" || fail "complete models"
PATH="$repo_dir/lmline:$PATH" LMLINE_CONFIG_DIR="$profiles_dir" bash --norc -i -c '
  source "$1/lmline/init.bash"
  COMP_WORDS=(lmline use "")
  COMP_CWORD=2
  __lmline_cli_complete
  printf "%s\n" "${COMPREPLY[@]}" | grep -q "^local$"
  COMP_WORDS=(lmline use cloud "")
  COMP_CWORD=3
  __lmline_cli_complete
  printf "%s\n" "${COMPREPLY[@]}" | grep -q "^openai/gpt-test$"
' _ "$repo_dir" || fail "bash profile completion"
if command -v zsh >/dev/null 2>&1; then
  PATH="$repo_dir/lmline:$PATH" LMLINE_CONFIG_DIR="$profiles_dir" zsh -fic '
    source "$1/lmline/init.zsh"
    compadd() { print -r -- "${@:2}" >>"$OUT"; }
    OUT=/tmp/lmline-zsh-complete-endpoints.out
    : >"$OUT"
    words=(lmline use "")
    CURRENT=3
    _lmline
    grep -q "^local$" /tmp/lmline-zsh-complete-endpoints.out
    OUT=/tmp/lmline-zsh-complete-models.out
    : >"$OUT"
    words=(lmline use cloud "")
    CURRENT=4
    _lmline
    grep -q "^openai/gpt-test$" /tmp/lmline-zsh-complete-models.out
  ' _ "$repo_dir" /tmp/lmline-zsh-complete.out || fail "zsh profile completion"
fi
LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" use local local-test-model
profile_config=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" config get)
grep -q "LMLINE_BASE_URL=.*http://127.0.0.1:1234/v1" <<<"$profile_config" || fail "use base url"
grep -q "LMLINE_MODEL=.*local-test-model" <<<"$profile_config" || fail "use model"
grep -q "LMLINE_TEMPERATURE=.*0.3" <<<"$profile_config" || fail "use model temperature override"
grep -q "LMLINE_MAX_TOKENS=.*600" <<<"$profile_config" || fail "use endpoint max tokens fallback"
grep -q "LMLINE_TOOL_MODE=.*auto" <<<"$profile_config" || fail "use model tool mode override"
current_out=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" current)
grep -q '^endpoint=local$' <<<"$current_out" || fail "current endpoint"
grep -q '^profile_status=matched$' <<<"$current_out" || fail "current matched"
if LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model add "bad name" model >/tmp/lmline-profile-bad.out 2>/tmp/lmline-profile-bad.err; then
  fail "invalid endpoint name rejected"
fi
grep -q "invalid endpoint name" /tmp/lmline-profile-bad.err || fail "invalid endpoint error"
if LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint add bad "ftp://example.invalid/v1" >/tmp/lmline-profile-bad-url.out 2>/tmp/lmline-profile-bad-url.err; then
  fail "invalid endpoint url rejected"
fi
grep -q "invalid base_url" /tmp/lmline-profile-bad-url.err || fail "invalid endpoint url error"
if LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" endpoint add bad-tool https://example.invalid/v1 --tool-mode maybe >/tmp/lmline-profile-bad-tool.out 2>/tmp/lmline-profile-bad-tool.err; then
  fail "invalid endpoint tool mode rejected"
fi
grep -q "invalid tool_mode" /tmp/lmline-profile-bad-tool.err || fail "invalid tool mode error"
if LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model add local bad-model --max-tokens nope >/tmp/lmline-profile-bad-tokens.out 2>/tmp/lmline-profile-bad-tokens.err; then
  fail "invalid model max tokens rejected"
fi
grep -q "invalid max_tokens" /tmp/lmline-profile-bad-tokens.err || fail "invalid max tokens error"
fake_refresh_bin="$cfg_tmp/profile-refresh-bin"
mkdir -p "$fake_refresh_bin"
cat >"$fake_refresh_bin/curl" <<'EOF'
#!/usr/bin/env bash
url=${@: -1}
[[ "$url" == "https://llm.example/v2/models" ]] || { echo "unexpected url: $url" >&2; exit 8; }
prev=
for arg in "$@"; do
  if [[ "$prev" == "-H" && "$arg" == @* ]]; then
    grep -qx 'X-Api-Key: cloud-secret' "${arg#@}" && found=1
  fi
  [[ "$arg" == *cloud-secret* ]] && leaked=1
  prev=$arg
done
[[ "${found:-0}" == 1 ]] || { echo "missing auth" >&2; exit 7; }
[[ "${leaked:-0}" == 0 ]] || { echo "secret leaked into curl argv" >&2; exit 6; }
printf '{"data":[{"id":"cloud/model-a"},{"id":"cloud/model-b"}]}\n'
EOF
chmod +x "$fake_refresh_bin/curl"
PATH="$fake_refresh_bin:$PATH" LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model refresh cloud
refresh_models=$(LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model list cloud)
grep -q $'^cloud\tcloud/model-a' <<<"$refresh_models" || fail "refresh model a"
grep -q $'^cloud\tcloud/model-b' <<<"$refresh_models" || fail "refresh model b"
cat >"$fake_refresh_bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 9
EOF
before_failed_refresh=$(cat "$profiles_dir/models.tsv")
if PATH="$fake_refresh_bin:$PATH" LMLINE_CONFIG_DIR="$profiles_dir" "$repo_dir/lmline/lmline" model refresh cloud >/tmp/lmline-refresh-fail.out 2>/tmp/lmline-refresh-fail.err; then
  fail "refresh failure rejected"
fi
[[ "$(cat "$profiles_dir/models.tsv")" == "$before_failed_refresh" ]] || fail "refresh failure preserved models"
install_like_dir="$cfg_tmp/install-like"
install_like_bin="$cfg_tmp/bin"
mkdir -p "$install_like_dir" "$install_like_bin"
cp "$repo_dir/lmline/"{lmline,config.bash,context.bash,policy.bash,actions.bash,http.bash,profiles.bash,chat.bash,engine} "$install_like_dir/"
cp -R "$repo_dir/lmline/defaults" "$install_like_dir/defaults"
mkdir -p "$install_like_dir/prompts"
cp "$repo_dir/lmline/prompts/"*.txt "$install_like_dir/prompts/"
ln -s "$install_like_dir/lmline" "$install_like_bin/lmline"
LMLINE_CONFIG_DIR="$install_like_dir" "$install_like_bin/lmline" context "# list files" | grep -q "^## suggested_commands$" || fail "installed symlink command resolves support files"
LMLINE_CONFIG_DIR="$install_like_dir" "$install_like_bin/lmline" config set LMLINE_BASE_URL http://127.0.0.1:1234/v1
grep -q "LMLINE_BASE_URL" "$install_like_dir/settings.bash" || fail "installed config writes settings file"
! grep -q "LMLINE_BASE_URL" "$install_like_dir/config.bash" || fail "installed config must not modify support helper"
LMLINE_CONFIG_DIR="$install_like_dir" "$install_like_bin/lmline" config get | grep -q "LMLINE_BASE_URL" || fail "installed config get reads settings"
! LMLINE_CONFIG_DIR="$install_like_dir" "$install_like_bin/lmline" config get | grep -q "__lmline_quote_single" || fail "installed config get must not print support helper"
(
  cd "$cfg_tmp"
  LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config project-set LMLINE_ASYNC 1
  LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config project-get | grep -q "LMLINE_ASYNC=.*1"
  LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config project-unset LMLINE_ASYNC
  ! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config project-get | grep -q "LMLINE_ASYNC="
)
safe_project=$(mktemp -d "${TMPDIR:-/tmp}/lmline-safe-project.XXXXXX")
(
  cd "$safe_project"
  printf "%s\n" \
    "export LMLINE_BASE_URL='http://127.0.0.1:1234/v1'" \
    "export LMLINE_MODEL='project-safe-model'" \
    "export LMLINE_ASYNC=\$(touch '$safe_project/should-not-exist')" >.lmline.bash
  LMLINE_CONFIG_DIR="$cfg_tmp/config-safe" "$repo_dir/lmline/lmline" payload generate "# request" >"$safe_project/payload.json"
  grep -q '"model": "project-safe-model"' "$safe_project/payload.json"
  [[ ! -e "$safe_project/should-not-exist" ]]
)
rm -rf "$safe_project"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" risk "rm -rf build" | grep -q "risk=high" || fail "risk cli"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## suggested_commands$" || fail "context cli"
! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## available_commands$" || fail "context cli sent full command list"
! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## files$" || fail "context cli sent file list"
! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## recent_history$" || fail "context cli sent history"
! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## edit_tendencies$" || fail "context cli sent lmline history"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^command_exists commands=" || fail "context tool list"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^command_info commands=" || fail "context command_info tool list"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "Local action: command -v" || fail "context tool action"
! LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## available_tools$" || fail "context tool list disabled with tool mode none"
empty_suggestions_dir="$cfg_tmp/empty-suggestions"
mkdir -p "$empty_suggestions_dir"
: >"$empty_suggestions_dir/suggested_commands.txt"
! LMLINE_CONFIG_DIR="$empty_suggestions_dir" "$repo_dir/lmline/lmline" context "# list files" | grep -q "^## suggested_commands$" || fail "context omitted empty suggested commands"
risk_dir="$cfg_tmp/risk"
mkdir -p "$risk_dir"
printf 'high\t*deploy production*\tcustom deployment pattern\n' >"$risk_dir/risk_patterns.tsv"
LMLINE_CONFIG_DIR="$risk_dir" "$repo_dir/lmline/lmline" risk "deploy production now" | grep -q "reason=custom deployment pattern" || fail "custom risk patterns"
if LMLINE_SUGGESTED_COMMANDS_FILE="$cfg_tmp/missing-suggested-commands.txt" LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files" >/tmp/lmline-missing-suggestions.out 2>/tmp/lmline-missing-suggestions.err; then
  fail "missing explicit suggested commands file failed open"
fi
grep -q "suggested_commands file is not readable" /tmp/lmline-missing-suggestions.err || fail "missing suggested commands error"
if LMLINE_RISK_PATTERNS_FILE="$cfg_tmp/missing-risk-patterns.tsv" LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" risk "echo hi" >/tmp/lmline-missing-risk.out 2>/tmp/lmline-missing-risk.err; then
  fail "missing explicit risk patterns file failed open"
fi
grep -q "risk_patterns file is not readable" /tmp/lmline-missing-risk.err || fail "missing risk patterns error"
command_exists_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" command-exists awk definitely-not-a-command-for-lmline)
grep -q $'^awk\tfound\t' <<<"$command_exists_out" || fail "command-exists found"
grep -q $'^definitely-not-a-command-for-lmline\tmissing$' <<<"$command_exists_out" || fail "command-exists missing"
command_info_out=$(LMLINE_TOOL_INFO_LINES=4 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" command-info echo definitely-not-a-command-for-lmline)
grep -q '^### echo$' <<<"$command_info_out" || fail "command-info heading"
grep -q '^exists=found$' <<<"$command_info_out" || fail "command-info found"
grep -q '^kind=builtin$' <<<"$command_info_out" || fail "command-info kind"
grep -q '^BEGIN_UNTRUSTED_TYPE_OUTPUT$' <<<"$command_info_out" || fail "command-info untrusted block"
grep -q '^### definitely-not-a-command-for-lmline$' <<<"$command_info_out" || fail "command-info missing heading"
grep -q '^exists=missing$' <<<"$command_info_out" || fail "command-info missing"
fake_portable_bin="$cfg_tmp/fake-portable-bin"
mkdir -p "$fake_portable_bin"
cat >"$fake_portable_bin/date" <<'EOF'
#!/usr/bin/env bash
printf 'fake-date invoked'
for arg in "$@"; do printf ' %s' "$arg"; done
printf '\n'
EOF
chmod +x "$fake_portable_bin/date"
linux_command_info=$(PATH="$fake_portable_bin:$PATH" OSTYPE=linux-gnu bash -c 'source "$1/lmline/config.bash"; source "$1/lmline/context.bash"; __lmline_tool_command_info date' _ "$repo_dir")
grep -q 'fake-date invoked --version' <<<"$linux_command_info" || fail "command-info linux version probe"
darwin_command_info=$(PATH="$fake_portable_bin:$PATH" OSTYPE=darwin23 bash -c 'source "$1/lmline/config.bash"; source "$1/lmline/context.bash"; __lmline_tool_command_info date' _ "$repo_dir")
! grep -q 'fake-date invoked --version' <<<"$darwin_command_info" || fail "command-info darwin avoids GNU probe"
safe_text_out=$(printf '\033[31mRED\033[0m abcdefghijklmnopqrstuvwxyz\n' | bash -c 'source "$1/lmline/context.bash"; __lmline_safe_tool_text 5 10' _ "$repo_dir")
[[ "$safe_text_out" == "RED abcdef...<truncated>" ]] || fail "safe tool text"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" commands aw | grep -q "^awk$" || fail "commands cli"
! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" commands lmline | grep -q "^__lmline_" || fail "commands cli leaked internals"
doctor_dir="$cfg_tmp/doctor"
mkdir -p "$doctor_dir"
printf 'definitely-not-a-command-for-lmline\n' >"$doctor_dir/doctor_required_commands.txt"
printf 'awk\n' >"$doctor_dir/doctor_optional_commands.txt"
doctor_out=$(LMLINE_CONFIG_DIR="$doctor_dir" "$repo_dir/lmline/lmline" doctor)
grep -q "missing command=definitely-not-a-command-for-lmline" <<<"$doctor_out" || fail "custom doctor commands"
grep -q "install definitely-not-a-command-for-lmline or check PATH" <<<"$doctor_out" || fail "doctor missing command hint"
grep -q "lmline endpoint set-secret ENDPOINT" <<<"$doctor_out" || fail "doctor auth hint"
grep -q '^engine=.* (ok)$' <<<"$doctor_out" || fail "doctor engine status"
grep -q '^defaults$' <<<"$doctor_out" || fail "doctor defaults heading"
grep -q 'risk_patterns.tsv: ok' <<<"$doctor_out" || fail "doctor defaults risk patterns"
grep -q 'suggested_commands.txt: ok' <<<"$doctor_out" || fail "doctor defaults suggested commands"
doctor_api_bin="$cfg_tmp/doctor-api-bin"
mkdir -p "$doctor_api_bin"
printf '#!/usr/bin/env bash\nexit 7\n' >"$doctor_api_bin/curl"
chmod +x "$doctor_api_bin/curl"
doctor_api_out=$(PATH="$doctor_api_bin:$PATH" LMLINE_BASE_URL=http://127.0.0.1:9/v1 LMLINE_CONFIG_DIR="$doctor_dir" "$repo_dir/lmline/lmline" doctor --check-api)
grep -q 'connection=failed' <<<"$doctor_api_out" || fail "doctor api failure"
grep -q 'lmline use ENDPOINT MODEL' <<<"$doctor_api_out" || fail "doctor api hint"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" debug trace on
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config get | grep -q "LMLINE_TRACE_DIR=" || fail "trace config on"
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" debug trace off
! LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config get | grep -q "LMLINE_TRACE_DIR=" || fail "trace config off"
payload_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload generate "# list files")
grep -q '"model": "test-model"' <<<"$payload_out" || fail "payload model"
grep -q '"messages":' <<<"$payload_out" || fail "payload messages"
grep -q 'Requested candidate limit: 3' <<<"$payload_out" || fail "payload candidate limit"
grep -q 'Maximum candidate line length: 4096 bytes' <<<"$payload_out" || fail "payload candidate length limit"
grep -q 'Tool round budget: current=0 max=10' <<<"$payload_out" || fail "payload tool round budget"
grep -q 'Tool calls per round limit: 20' <<<"$payload_out" || fail "payload tool call limit"
grep -q 'Unix-style pipelines' <<<"$payload_out" || fail "payload one-line pipeline instruction"
grep -q 'aim to return multiple distinct candidates' <<<"$payload_out" || fail "payload multi-candidate instruction"
[[ $(grep -o 'aim to return multiple distinct candidates' <<<"$payload_out" | wc -l | tr -d ' ') == 1 ]] || fail "payload multi-candidate instruction duplicated"
payload_explain_long_cmd=$(printf "printf %%s "; printf "c%.0s" {1..5000})
payload_explain_long=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload explain "$payload_explain_long_cmd")
payload_explain_user=$(printf '%s' "$payload_explain_long" | jq -r '.messages[] | select(.role == "user") | .content')
grep -Fq "$payload_explain_long_cmd" <<<"$payload_explain_user" || fail "payload explain sends long line"
grep -q '"max_tokens": 1200' <<<"$payload_explain_long" || fail "payload explain token budget"
grep -q 'Explanation detail: normal' <<<"$payload_explain_long" || fail "payload explain default detail"
payload_explain_ja=$(LC_ALL=C.UTF-8 LANG=ja_JP.UTF-8 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload explain "echo hi")
grep -q 'Response language: Japanese' <<<"$payload_explain_ja" || fail "payload explain locale language"
grep -q 'Answer in the response language' <<<"$payload_explain_ja" || fail "payload explain system language rule"
payload_explain_detailed=$(LMLINE_EXPLAIN_DETAIL=detailed LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload explain "echo hi")
grep -q 'Explanation detail: detailed' <<<"$payload_explain_detailed" || fail "payload explain detailed"
payload_clip=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload clip "Question: explain pasted error")
grep -q '"max_tokens": 1200' <<<"$payload_clip" || fail "payload clip token budget"
grep -q 'Answer a question about pasted terminal or clipboard text' <<<"$payload_clip" || fail "payload clip system"
payload_explain_bad_status=0
LMLINE_EXPLAIN_DETAIL=verbose LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload explain "echo hi" >/tmp/lmline-bad-detail.out 2>/tmp/lmline-bad-detail.err || payload_explain_bad_status=$?
[[ "$payload_explain_bad_status" != 0 ]] || fail "payload explain invalid detail status"
grep -q 'invalid LMLINE_EXPLAIN_DETAIL' /tmp/lmline-bad-detail.err || fail "payload explain invalid detail error"
grep -q 'suggested_commands' <<<"$payload_out" || fail "payload context"
grep -q '"tools":' <<<"$payload_out" || fail "default auto payload tools"
! grep -q '## available_commands' <<<"$payload_out" || fail "payload sent full command list"
! grep -q '## files' <<<"$payload_out" || fail "payload sent file list"
! grep -q '## recent_history' <<<"$payload_out" || fail "payload sent history"
! grep -q '## edit_tendencies' <<<"$payload_out" || fail "payload sent lmline history"
tool_payload_out=$(LMLINE_TOOL_MODE=openai LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload generate "# list files")
grep -q '"tools":' <<<"$tool_payload_out" || fail "payload tools"
grep -q '"name": "command_exists"' <<<"$tool_payload_out" || fail "payload command_exists tool"
grep -q '"name": "command_info"' <<<"$tool_payload_out" || fail "payload command_info tool"
grep -q 'runs command -v' <<<"$tool_payload_out" || fail "payload tool action"
explain_tool_payload_out=$(LMLINE_TOOL_MODE=openai LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload explain "date -r")
grep -q '"tools":' <<<"$explain_tool_payload_out" || fail "explain payload tools"
grep -q '"name": "command_info"' <<<"$explain_tool_payload_out" || fail "explain payload command_info tool"
grep -q 'check with command_info' <<<"$explain_tool_payload_out" || fail "explain payload tool instruction"
no_tool_payload_out=$(LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload generate "# list files")
! grep -q 'check with command_info' <<<"$no_tool_payload_out" || fail "no-tool payload sent tool instruction"
! grep -q 'TOOL command_exists' <<<"$no_tool_payload_out" || fail "no-tool payload sent text tool instruction"
grep -q 'untrusted data' <<<"$no_tool_payload_out" || fail "no-tool payload omitted untrusted data warning"
grep -q 'untrusted data' <<<"$tool_payload_out" || fail "tool payload omitted untrusted data warning"
date_rewrite_payload_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload rewrite 'date +"%Y/%m/%d %H:%M:%S (%Z)" #ニューヨーク時間を出したい')
grep -q 'Parsed inline intent:' <<<"$date_rewrite_payload_out" || fail "rewrite payload parsed inline intent"
grep -q 'Command before inline comment:' <<<"$date_rewrite_payload_out" || fail "rewrite payload command before comment"
grep -q 'Inline user intent:' <<<"$date_rewrite_payload_out" || fail "rewrite payload inline intent"
grep -q 'IANA timezone name' <<<"$date_rewrite_payload_out" || fail "rewrite payload timezone instruction"
url_comment_payload_out=$(LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload rewrite 'curl http://x.com#frag # fetch')
grep -q 'curl http://x.com#frag ' <<<"$url_comment_payload_out" || fail "rewrite payload preserves url fragment before comment"
grep -q 'Inline user intent:' <<<"$url_comment_payload_out" || fail "rewrite payload url inline intent"
disabled_tool_payload_out=$(LMLINE_TOOL_FILES=0 LMLINE_TOOL_COMMAND_INFO=0 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload generate "# list files")
grep -q '"name": "command_exists"' <<<"$disabled_tool_payload_out" || fail "enabled command_exists tool omitted"
grep -q '"name": "commands"' <<<"$disabled_tool_payload_out" || fail "enabled commands tool omitted"
! grep -q '"name": "command_info"' <<<"$disabled_tool_payload_out" || fail "disabled command_info tool sent"
! grep -q '"name": "files"' <<<"$disabled_tool_payload_out" || fail "disabled files tool sent"
disabled_tool_context_out=$(LMLINE_TOOL_FILES=0 LMLINE_TOOL_COMMAND_INFO=0 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files")
grep -q '^command_exists commands=' <<<"$disabled_tool_context_out" || fail "enabled command_exists context omitted"
! grep -q '^command_info commands=' <<<"$disabled_tool_context_out" || fail "disabled command_info context sent"
! grep -q '^files query=' <<<"$disabled_tool_context_out" || fail "disabled files context sent"
all_disabled_payload_out=$(LMLINE_TOOL_COMMAND_EXISTS=0 LMLINE_TOOL_COMMANDS=0 LMLINE_TOOL_COMMAND_INFO=0 LMLINE_TOOL_FILES=0 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" payload generate "# list files")
! grep -q '"tools":' <<<"$all_disabled_payload_out" || fail "all disabled tools still sent"
! grep -q 'check with command_info' <<<"$all_disabled_payload_out" || fail "all disabled payload sent tool instruction"
all_disabled_context_out=$(LMLINE_TOOL_COMMAND_EXISTS=0 LMLINE_TOOL_COMMANDS=0 LMLINE_TOOL_COMMAND_INFO=0 LMLINE_TOOL_FILES=0 LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" context "# list files")
! grep -q '^## available_tools$' <<<"$all_disabled_context_out" || fail "all disabled tools context heading sent"
files_tmp="$cfg_tmp/files"
mkdir -p "$files_tmp/node_modules/pkg" "$files_tmp/src" "$files_tmp/.git"
printf 'x\n' >"$files_tmp/node_modules/pkg/ignored.js"
printf 'x\n' >"$files_tmp/src/kept.sh"
printf 'node_modules\n.git\n' >"$cfg_tmp/config/file_search_excludes.txt"
files_out=$(cd "$files_tmp" && LMLINE_CONFIG_DIR="$cfg_tmp/config" bash -c 'source "$1/lmline/config.bash"; __lmline_init_dirs "$1/lmline"; source "$1/lmline/context.bash"; __lmline_collect_files' _ "$repo_dir")
grep -q '^src/kept.sh$' <<<"$files_out" || fail "collect files kept source file"
! grep -q 'node_modules' <<<"$files_out" || fail "collect files excluded node_modules"

rm -rf "$cfg_tmp"
ok "cli, config, and profiles"
