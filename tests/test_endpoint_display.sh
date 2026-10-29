#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-endpoint-display.XXXXXX")
trap 'rm -rf "$work"' EXIT
raw_endpoint=$'endpoint_\302\23552;c;payload\302\234suffix'
label=endpoint_suffix
unicode_endpoint='unicode-端点'
config_dir=$work/config
lmline=$repo_dir/lmline/lmline
cli() { LMLINE_CONFIG_DIR="$config_dir" "$lmline" "$@"; }
# Never include terminal-control fixtures or command output in test diagnostics.
safe_output() {
  [[ "$1" != *$'\302\235'* && "$1" != *$'\302\234'* && "$1" != *$'\033'* ]] || fail "$2 contains terminal controls"
}
rejected() {
  if cli "$@" >"$work/rejected.out" 2>"$work/rejected.err"; then
    fail 'invalid selection unexpectedly succeeded'
  fi
  rejected_error=$(cat "$work/rejected.err")
  safe_output "$rejected_error" 'rejection diagnostic'
}
for endpoint in "$raw_endpoint" "$label" ordinary "$unicode_endpoint"; do
  cli endpoint add "$endpoint" https://endpoint.example/v1 >/dev/null
  cli model add "$endpoint" first >/dev/null
done
cli model add "$raw_endpoint" second >/dev/null
stored_names=$(cut -f1 "$config_dir/endpoints.tsv")
grep -Fxq "$raw_endpoint" <<<"$stored_names" || fail 'storage preserves raw endpoint names'
# Terminal-facing endpoint candidates are safe by default; shell integrations
# explicitly request the lossless transport and quote before insertion.
safe_completion=$(cli complete endpoints)
safe_output "$safe_completion" 'endpoint completion labels'
expected_completion=$(printf '%s\n' "$label" "$label" ordinary "$unicode_endpoint")
[[ "$safe_completion" == "$expected_completion" ]] || fail 'endpoint completion defaults to safe readable labels'
raw_completion=$(cli complete endpoints --raw)
[[ "$raw_completion" == "$stored_names" ]] || fail 'endpoint completion transport preserves exact raw names'
raw_rows=$(
  # shellcheck source=lmline/profiles.bash
  source "$repo_dir/lmline/profiles.bash"
  endpoints_file=$config_dir/endpoints.tsv
  models_file=$config_dir/models.tsv
  profile_endpoint_list
  profile_model_list "$raw_endpoint"
)
grep -Fq "$raw_endpoint" <<<"$raw_rows" || fail 'raw profile list adapters stay lossless'
list=$(cli endpoint list)
safe_output "$list" 'endpoint list'
[[ $(cut -f1 <<<"$list") == $(printf '%s\n' "$label" "$label" ordinary "$unicode_endpoint") ]] || fail 'endpoint list preserves ordinary and Unicode labels'
raw_list=$(cli endpoint list --raw)
[[ $(cut -f1 <<<"$raw_list") == "$stored_names" ]] || fail 'raw endpoint list preserves exact stored names'
model_list=$(cli model list "$raw_endpoint")
safe_output "$model_list" 'model list'
[[ $(cut -f1,2 <<<"$model_list") == $(printf '%s\tfirst\n%s\tsecond' "$label" "$label") ]] || fail 'model list filters by raw endpoint before rendering'
[[ $(cli complete models --raw "$raw_endpoint") == $'first\nsecond' ]] || fail 'model completion filters by the exact raw endpoint'

# Ambiguous and empty selections offer shell words that recover the raw name.
LC_ALL=C printf -v quoted_endpoint '%q' "$raw_endpoint"
rejected use "$raw_endpoint"
[[ "$rejected_error" == *"multiple models registered for $label"* ]] || fail 'ambiguous selection uses a safe endpoint label'
[[ "$rejected_error" == *"lmline use $quoted_endpoint first"* ]] || fail 'choice hint quotes the endpoint reversibly'
# Execute only the generated hint with a local argument-checking stub, not lmline.
hint=$(sed -n '/^  lmline use /{s/^  //;p;q;}' "$work/rejected.err")
(
  lmline() { [[ $# == 3 && $1 == use && $2 == "$raw_endpoint" && $3 == first ]]; }
  eval "$hint"
) || fail 'choice hint recovers the exact raw endpoint'
cli endpoint add "empty-$raw_endpoint" https://empty.example/v1 >/dev/null
rejected use "empty-$raw_endpoint"
LC_ALL=C printf -v quoted_empty '%q' "empty-$raw_endpoint"
[[ "$rejected_error" == *"lmline model refresh $quoted_empty (or lmline model add $quoted_empty MODEL)"* ]] || fail 'empty selection quotes both command hints'

# Explicit lookup/selection and both current matching paths retain raw keys.
cli use "$raw_endpoint" first >/dev/null
saved_endpoint=$(
  # shellcheck disable=SC1090
  source "$config_dir/settings.bash"
  printf '%s' "$LMLINE_ACTIVE_ENDPOINT"
)
[[ "$saved_endpoint" == "$raw_endpoint" ]] || fail 'selection stores the exact raw endpoint'
current=$(cli current)
safe_output "$current" 'current'
[[ "$current" == *$'endpoint=endpoint_suffix\nprofile_status=matched'* ]] || fail 'current matches raw selection and renders a safe endpoint'
config_get=$(cli config get)
safe_output "$config_get" 'config get'
[[ "$config_get" == *"LMLINE_ACTIVE_ENDPOINT='endpoint_suffix'"* ]] || fail 'config get renders the selected endpoint safely'
config_effective=$(cli config effective)
safe_output "$config_effective" 'config effective'
[[ "$config_effective" == *$'LMLINE_ACTIVE_ENDPOINT\tendpoint_suffix\t'* ]] || fail 'config effective renders the selected endpoint safely'
config_description=$(cli config describe LMLINE_ACTIVE_ENDPOINT)
safe_output "$config_description" 'config description'
[[ "$config_description" == *$'value=endpoint_suffix\n'* ]] || fail 'config describe renders the selected endpoint safely'
mkdir -p "$work/project"
(
  cd "$work/project"
  cli config project-set LMLINE_ACTIVE_ENDPOINT "$raw_endpoint"
  project_config=$(cli config project-get)
  safe_output "$project_config" 'project config get'
  [[ "$project_config" == *"LMLINE_ACTIVE_ENDPOINT='endpoint_suffix'"* ]] || fail 'project config renders endpoint safely'
)
sed '/LMLINE_ACTIVE_ENDPOINT=/d' "$config_dir/settings.bash" >"$work/fallback-settings"
cp "$work/fallback-settings" "$config_dir/settings.bash"
fallback=$(cli current)
safe_output "$fallback" 'fallback current'
[[ "$fallback" == *$'endpoint=endpoint_suffix\nprofile_status=matched'* ]] || fail 'base URL fallback renders a safe endpoint'
for endpoint in ordinary "$unicode_endpoint"; do
  cli use "$endpoint" first >/dev/null
  [[ $(cli current) == *"endpoint=$endpoint"* ]] || fail 'ordinary and Unicode selection stays readable'
done
cli use "$raw_endpoint" first >/dev/null

unknown="missing-$raw_endpoint"
rejected use "$unknown"
rejected model add "$unknown" first
rejected model refresh "$unknown"
rejected endpoint remove "$unknown"
rejected endpoint set-secret "$unknown"
rejected model remove "$raw_endpoint" missing
rejected use "$raw_endpoint" missing
# Empty input exercises the prompt without ever storing or supplying a secret.
if printf '\n' | cli endpoint set-secret "$raw_endpoint" >"$work/prompt.out" 2>"$work/prompt.err"; then
  fail 'empty secret should be rejected'
fi
prompt=$(cat "$work/prompt.err")
safe_output "$prompt" 'secret prompt'
[[ "$prompt" == *"endpoint $label API key:"* ]] || fail 'secret prompt uses a safe endpoint label'
[[ ! -d "$config_dir/secrets" ]] || fail 'display test must not write secrets'

# Refresh uses the raw endpoint for its lookup, request URL, merge and warnings.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
[[ ${LMLINE_TEST_FETCH_FAIL:-0} == 0 ]] || exit 1
[[ ${!#} == https://endpoint.example/v1/models ]] || exit 1
printf '{"data":[{"id":"second"}]}\n'
CURL
chmod +x "$work/bin/curl"
PATH="$work/bin:$PATH" LMLINE_CONFIG_DIR="$config_dir" "$lmline" model refresh "$raw_endpoint" >"$work/refresh.out" 2>"$work/refresh.err" || fail 'raw endpoint refresh succeeds'
refresh=$(cat "$work/refresh.err")
safe_output "$refresh" 'refresh summary'
[[ "$refresh" == *"models for $label"* && "$refresh" == *"no longer served by $label; run lmline use $quoted_endpoint MODEL"* ]] || fail 'refresh summary and removed selection warning render endpoints safely'
[[ $(cli complete models --raw "$raw_endpoint") == second ]] || fail 'refresh merges under the exact raw endpoint'
[[ $(cli complete models --raw "$label") == first ]] || fail 'refresh leaves display-colliding endpoints alone'
if PATH="$work/bin:$PATH" LMLINE_TEST_FETCH_FAIL=1 cli model refresh "$raw_endpoint" >"$work/fetch.out" 2>"$work/fetch.err"; then
  fail 'failed fetch must fail'
fi
fetch_error=$(cat "$work/fetch.err")
safe_output "$fetch_error" 'refresh failure'
[[ "$fetch_error" == *"model refresh failed for endpoint: $label"* ]] || fail 'refresh failure uses a safe endpoint label'

# Doctor's invalid-jq and orphan warnings use labels, not raw endpoint bytes.
printf '%s\thttps://invalid.example/v1\t\t\t\t\t\t\t\t[\t\t\t\tapi-key\n' "$raw_endpoint" >>"$config_dir/endpoints.tsv"
printf '%s\tmissing\t\t\t\tchat\n' "$unknown" >>"$config_dir/models.tsv"
doctor=$(cli doctor)
safe_output "$doctor" 'doctor'
[[ "$doctor" == *"endpoint $label has an invalid models_jq"* ]] || fail 'doctor sanitizes endpoint validation warnings'
[[ "$doctor" == *"unknown endpoint: missing-$label/missing"* ]] || fail 'doctor sanitizes orphan endpoint warnings'
cli endpoint remove "$raw_endpoint" --keep-secret >"$work/remove.out" 2>"$work/remove.err"
remove=$(cat "$work/remove.err")
safe_output "$remove" 'endpoint removal'
[[ "$remove" == *"removed endpoint $label was active"* ]] || fail 'active endpoint removal uses a safe label'
[[ $(cli complete models --raw "$label") == first ]] || fail 'removal keeps display-colliding endpoint models'
ok 'endpoint displays are terminal-safe while raw lookup and selection remain exact'
