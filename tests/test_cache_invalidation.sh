#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: a changed effective request identity must miss cache while an identical request hits it.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-cache-invalidation-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_BASE_URL https://mock.invalid/v1
LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/lmline" config set LMLINE_MODEL test-model
printf 'echo hi\n' >"$cfg_tmp/line"
printf '## available_tools\n' >"$cfg_tmp/context"
fake_bin="$cfg_tmp/fake-bin"
mkdir -p "$fake_bin"

# Mock transport: answers from the request's own Response language directive
# and counts invocations, so cache hits are observable without a network.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"${LMLINE_FAKE_CURL_CALLS:?}"
payload=
prev=
for arg in "$@"; do
  if [[ "$prev" == "--data-binary" ]]; then payload=${arg#@}; fi
  prev=$arg
done
if grep -q "Japanese" "$payload" 2>/dev/null; then marker="mock explanation in Japanese"; else marker="mock explanation in English"; fi
if [[ -n "${LMLINE_FAKE_CURL_CONTENT:-}" ]]; then marker=$LMLINE_FAKE_CURL_CONTENT; fi
out=
prev=
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then out=$arg; fi
  prev=$arg
done
printf '{"choices":[{"message":{"role":"assistant","content":"%s"}}]}\n' "$marker" >"$out"
printf '200\tapplication/json'
EOF
chmod +x "$fake_bin/curl"

run_explain() {
  LMLINE_RESPONSE_LOCALE="$1" LMLINE_CACHE_TTL="$2" PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_CALLS="$cfg_tmp/calls.log" \
    LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode explain --format plain \
    --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 \
    >"$cfg_tmp/out.txt" 2>"$cfg_tmp/err.txt"
  cat "$cfg_tmp/out.txt"
}

: >"$cfg_tmp/calls.log"
[[ $(run_explain en 60) == "mock explanation in English" ]] || fail "initial english answer"
[[ $(grep -c called "$cfg_tmp/calls.log") == 1 ]] || fail "initial transport call"
# Unchanged repeat still hits the cache.
[[ $(run_explain en 60) == "mock explanation in English" ]] || fail "repeated english answer"
grep -q "tokens=cached" "$cfg_tmp/err.txt" || fail "repeat cache hit"
[[ $(grep -c called "$cfg_tmp/calls.log") == 1 ]] || fail "repeat transport call"
# A changed response language must not be served the stale cached answer.
[[ $(run_explain ja 60) == "mock explanation in Japanese" ]] || fail "japanese answer after locale change"
[[ $(grep -c called "$cfg_tmp/calls.log") == 2 ]] || fail "locale change transport call"
# The new answer is cached under its own key.
[[ $(run_explain ja 60) == "mock explanation in Japanese" ]] || fail "repeated japanese answer"
grep -q "tokens=cached" "$cfg_tmp/err.txt" || fail "japanese repeat cache hit"
[[ $(grep -c called "$cfg_tmp/calls.log") == 2 ]] || fail "japanese repeat transport call"

# A cached candidate the engine would now refuse is served by neither
# format: the plain format re-applies the same validation the annotated
# one does, so the entry is dropped and the request refetched.
cache_dir="$cfg_tmp/config/cache"
mkdir -p "$cache_dir"
# The cache key covers the mode, so the entry is written by a first generate
# request and then replaced with a candidate the engine would refuse.
: >"$cfg_tmp/calls.log"
LMLINE_FAKE_CURL_CONTENT="echo cached" LMLINE_RESPONSE_LOCALE=en LMLINE_CACHE_TTL=60 PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_CALLS="$cfg_tmp/calls.log" \
  LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --format plain \
  --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 \
  >"$cfg_tmp/first.out" 2>"$cfg_tmp/first.err" || fail "the first generate request failed"
grep -q 'echo cached' "$cfg_tmp/first.out" || fail "the first generate request served no candidate"
for entry in "$cache_dir"/*; do
  [[ -f "$entry" ]] || continue
  printf 'lmline-nonexistent-command-xyz --flag\n' >"$entry"
done
: >"$cfg_tmp/calls.log"
LMLINE_FAKE_CURL_CONTENT="echo cached" LMLINE_RESPONSE_LOCALE=en LMLINE_CACHE_TTL=60 PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_CALLS="$cfg_tmp/calls.log" \
  LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --format plain \
  --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 \
  >"$cfg_tmp/plain.out" 2>"$cfg_tmp/plain.err"
! grep -q 'lmline-nonexistent-command-xyz' "$cfg_tmp/plain.out" || fail "the plain format served a refused cached candidate"
[[ $(grep -c called "$cfg_tmp/calls.log") -ge 1 ]] || fail "the plain format did not refetch a refused cached candidate"
grep -q 'echo cached' "$cfg_tmp/plain.out" || fail "the plain format did not serve the refetched candidate"
: >"$cfg_tmp/calls.log"
LMLINE_FAKE_CURL_CONTENT="echo cached" LMLINE_RESPONSE_LOCALE=en LMLINE_CACHE_TTL=60 PATH="$fake_bin:$PATH" LMLINE_FAKE_CURL_CALLS="$cfg_tmp/calls.log" \
  LMLINE_CONFIG_DIR="$cfg_tmp/config" "$repo_dir/lmline/engine" --mode generate --format annotated \
  --shell bash --cwd "$repo_dir" --point 0 --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 \
  >"$cfg_tmp/annotated.out" 2>"$cfg_tmp/annotated.err"
! grep -q 'lmline-nonexistent-command-xyz' "$cfg_tmp/annotated.out" || fail "the annotated format served a refused cached candidate"

ok "cache invalidates on effective request change"
