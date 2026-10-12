#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-curl-isolation-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model
printf '# list files\n' >"$cfg_tmp/line"
printf '## available_tools\n' >"$cfg_tmp/context"
fake_bin="$cfg_tmp/fake-bin"
mkdir -p "$fake_bin"

# Recording fake curl: logs the first argument of every invocation so the
# test can assert provider requests start with -q (implicit curlrc ignored),
# then serves canned chat-completions responses (SSE for -N streams).
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${LMLINE_FAKE_CURL_ARGV0:?}"
streaming=0
out=
while (($#)); do
  case "$1" in
    -N) streaming=1; shift ;;
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
if (( streaming )); then
  cat <<'SSE'
data: {"choices":[{"delta":{"content":"streamed line"},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

data: [DONE]

SSE
  exit 0
fi
cat >"$out" <<'JSON'
{"model":"m","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"message":{"role":"assistant","content":"echo recorded"},"finish_reason":"stop"}]}
JSON
printf '200\tapplication/json'
EOF
chmod +x "$fake_bin/curl"

# Every provider request must disable implicit curlrc with first-argument -q.
assert_isolated_requests() {
  local log=$1 label=$2
  grep -qx -- '-q' "$log" || fail "$label: no isolated request recorded"
  ! grep -vx -- '-q' "$log" || fail "$label: request without leading -q"
}

# Regular (buffered) generate path.
: >"$cfg_tmp/argv0-regular.log"
regular_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_ARGV0="$cfg_tmp/argv0-regular.log" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
grep -q 'echo recorded' <<<"$regular_out" || fail "regular generate candidate"
assert_isolated_requests "$cfg_tmp/argv0-regular.log" "regular generate"

# Streaming explain path.
: >"$cfg_tmp/argv0-stream.log"
stream_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_ARGV0="$cfg_tmp/argv0-stream.log" LMLINE_STREAM=1 LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config" \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
grep -q 'streamed line' <<<"$stream_out" || fail "streamed candidate"
assert_isolated_requests "$cfg_tmp/argv0-stream.log" "stream explain"

# Doctor API probe (the informational curl --version call is exempt).
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${LMLINE_FAKE_CURL_ARGV0:?}"
while (($#)); do
  case "$1" in
    --version) printf 'curl 7.88.1\n'; exit 0 ;;
    *) shift ;;
  esac
done
printf '200'
EOF
chmod +x "$fake_bin/curl"
: >"$cfg_tmp/argv0-doctor.log"
doctor_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_ARGV0="$cfg_tmp/argv0-doctor.log" LMLINE_CONFIG_DIR="$cfg_tmp/config" \
  "$repo_dir/lmline/lmline" doctor --check-api)
grep -q 'connection=ok' <<<"$doctor_out" || fail "doctor probe connection"
grep -qx -- '-q' "$cfg_tmp/argv0-doctor.log" || fail "doctor probe: no isolated request recorded"
! grep -vx -e '-q' -e '--version' "$cfg_tmp/argv0-doctor.log" || fail "doctor probe: request without leading -q"

# Model catalog refresh path (__lmline_http_get).
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${LMLINE_FAKE_CURL_ARGV0:?}"
printf '{"data":[{"id":"catalog/m1"}]}\n'
EOF
chmod +x "$fake_bin/curl"
: >"$cfg_tmp/argv0-refresh.log"
LMLINE_CONFIG_DIR="$cfg_tmp/config-refresh" "$repo_dir/lmline/lmline" endpoint add catalog https://catalog.test.invalid/v1
PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_ARGV0="$cfg_tmp/argv0-refresh.log" LMLINE_CONFIG_DIR="$cfg_tmp/config-refresh" \
  "$repo_dir/lmline/lmline" model refresh catalog
LMLINE_CONFIG_DIR="$cfg_tmp/config-refresh" "$repo_dir/lmline/lmline" model list catalog | grep -q 'catalog/m1' || fail "refresh catalog model"
assert_isolated_requests "$cfg_tmp/argv0-refresh.log" "model refresh"

# Engine model auto-discovery path.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${LMLINE_FAKE_CURL_ARGV0:?}"
state=${LMLINE_FAKE_CURL_STATE:?}
count=0
[[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1))
printf '%s\n' "$count" >"$state"
out=
while (($#)); do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    --data-binary) shift 2 ;;
    *) shift ;;
  esac
done
if [[ -z "$out" ]]; then
  printf '{"data":[{"id":"discovered/m1"}]}\n'
  exit 0
fi
cat >"$out" <<'JSON'
{"model":"m","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"choices":[{"message":{"role":"assistant","content":"echo discovered"},"finish_reason":"stop"}]}
JSON
printf '200\tapplication/json'
EOF
chmod +x "$fake_bin/curl"
LMLINE_CONFIG_DIR="$cfg_tmp/config-discovery" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://api.test.invalid/v1
printf '0\n' >"$cfg_tmp/fake-curl-state"
: >"$cfg_tmp/argv0-discovery.log"
discovery_out=$(PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_ARGV0="$cfg_tmp/argv0-discovery.log" LMLINE_FAKE_CURL_STATE="$cfg_tmp/fake-curl-state" LMLINE_TOOL_MODE=none LMLINE_CONFIG_DIR="$cfg_tmp/config-discovery" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1)
grep -q 'echo discovered' <<<"$discovery_out" || fail "discovery generate candidate"
[[ $(cat "$cfg_tmp/fake-curl-state") == 2 ]] || fail "discovery plus generate request count"
assert_isolated_requests "$cfg_tmp/argv0-discovery.log" "model discovery"

ok "curl requests ignore implicit curlrc"
