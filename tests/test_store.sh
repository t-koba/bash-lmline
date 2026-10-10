#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-store-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1 >/dev/null
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model >/dev/null
printf '# list files\n' >"$cfg_tmp/line"
printf '## available_tools\n' >"$cfg_tmp/context"
run_payload() {
  LMLINE_CONFIG_DIR="$cfg_tmp/config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --dry-run-payload 2>"$cfg_tmp/warn.err"
}

# chat default: explicit store:false
out=$(LMLINE_API_FORMAT=chat LMLINE_TOOL_MODE=none run_payload)
jq -e '.store == false' <<<"$out" >/dev/null || fail "chat default store:false"
# chat opt-in: store:true
out=$(LMLINE_API_FORMAT=chat LMLINE_TOOL_MODE=none LMLINE_STORE=1 run_payload)
jq -e '.store == true' <<<"$out" >/dev/null || fail "chat opt-in store:true"
# responses default: explicit store:false
out=$(LMLINE_API_FORMAT=responses LMLINE_TOOL_MODE=none run_payload)
jq -e '.store == false' <<<"$out" >/dev/null || fail "responses default store:false"
# messages: no store field
out=$(LMLINE_API_FORMAT=messages LMLINE_TOOL_MODE=none run_payload)
jq -e 'has("store") | not' <<<"$out" >/dev/null || fail "messages omits store"

# compat fallback: provider rejects store with 400, engine retries without it
fake_bin="$cfg_tmp/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
out=; data=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
bodies=${LMLINE_FAKE_CURL_BODIES:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
cp "$data" "$bodies/body-$count.json"
if (( count == 1 )); then
  jq -e 'has("store")' "$data" >/dev/null || { echo "first payload missing store" >&2; exit 7; }
  printf '{"error":{"message":"Unrecognized request argument supplied: store"}}\n' >"$out"
  printf '400\tapplication/json'
else
  jq -e 'has("store") | not' "$data" >/dev/null || { echo "retry payload keeps store" >&2; exit 7; }
  printf '{"choices":[{"message":{"role":"assistant","content":"echo store-fallback-ok"}}]}\n' >"$out"
  printf '200\tapplication/json'
fi
CURL
chmod +x "$fake_bin/curl"
printf '0\n' >"$cfg_tmp/fake-curl-state"
mkdir -p "$cfg_tmp/store-bodies"
store_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_FAKE_CURL_BODIES="$cfg_tmp/store-bodies" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/store.err")
[[ "$(candidates_of <<<"$store_out")" == "echo store-fallback-ok" ]] || fail "store fallback output"
[[ $(cat "$cfg_tmp/fake-curl-state") == 2 ]] || fail "store fallback count"
grep -q 'retrying without store field' "$cfg_tmp/store.err" || fail "store fallback progress"

# config catalog documents the new setting
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config describe LMLINE_STORE | grep -q '^default=0$' || fail "store describe default"

ok "store"
