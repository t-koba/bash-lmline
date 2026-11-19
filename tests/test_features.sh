#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: protocol metadata, retries, cache, streaming, endpoint CRUD, and risk contracts remain consistent.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-features-test.XXXXXX")
cfg_tmp=$(cd -- "$cfg_tmp" && pwd -P) || exit 1
trap 'rm -rf "$cfg_tmp"' EXIT
fake_bin="$cfg_tmp/bin"
mkdir -p "$fake_bin" "$cfg_tmp/config"
printf '# say hi\n' >"$cfg_tmp/line"
printf '## shell\n' >"$cfg_tmp/context"

engine_env=(LMLINE_CONFIG_DIR="$cfg_tmp/config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model)
run_engine() {
  env PATH="$fake_bin:$PATH" "${engine_env[@]}" "$@" \
    "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
    --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1
}

# --- annotated protocol: risk, reason, and truncated flags ------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
printf '%s' '{"model":"m","choices":[{"message":{"content":"rm -rf /tmp/x\necho safe"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
chmod +x "$fake_bin/curl"
annotated_out=$(run_engine LMLINE_TOOL_MODE=none 2>/dev/null) || fail "annotated engine run"
grep -q $'^lmline-candidate: high\trecursive remove\t-\trm -rf /tmp/x$' <<<"$annotated_out" || fail "annotated high risk line"
plain_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
  --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 --format plain 2>/dev/null) || fail "plain engine run"
[[ "$plain_out" == "rm -rf /tmp/x" ]] || fail "plain format output"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
long=$(printf "printf %%s "; printf "a%.0s" {1..5000})
printf '{"choices":[{"message":{"content":%s},"finish_reason":"stop"}]}' "$(jq -Rn --arg s "$long" '$s')" >"$out"
printf '200\tapplication/json'
EOF
truncated_out=$(run_engine LMLINE_TOOL_MODE=none 2>/dev/null) || fail "truncated engine run"
grep -q $'\ttruncated\t' <<<"$truncated_out" || fail "truncated flag annotated"
[[ $(candidates_of <<<"$truncated_out" | LC_ALL=C wc -c | tr -d ' ') -le 4097 ]] || fail "truncated candidate length"

# --- 429 retry ---------------------------------------------------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
if (( count == 1 )); then
  printf '' >"$out"
  printf '429\tapplication/json'
else
  printf '{"choices":[{"message":{"content":"echo retried"},"finish_reason":"stop"}]}' >"$out"
  printf '200\tapplication/json'
fi
EOF
printf '0\n' >"$cfg_tmp/retry-state"
retry_out=$(run_engine LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/retry-state" LMLINE_RETRY_DELAY=0 2>"$cfg_tmp/retry.err") || fail "retry engine run"
[[ "$(candidates_of <<<"$retry_out")" == "echo retried" ]] || fail "429 retry output"
[[ $(cat "$cfg_tmp/retry-state") == 2 ]] || fail "429 retry count"
grep -q 'lmline-progress: transient provider error; retrying (1/1)' "$cfg_tmp/retry.err" || fail "429 retry progress"
printf '0\n' >"$cfg_tmp/retry-state"
if run_engine LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/retry-state" LMLINE_RETRY_DELAY=0 LMLINE_HTTP_RETRIES=0 >/dev/null 2>"$cfg_tmp/retry0.err"; then
  fail "retries disabled should fail on 429"
fi
[[ $(cat "$cfg_tmp/retry-state") == 1 ]] || fail "retries disabled request count"

# --- response cache ----------------------------------------------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
printf '{"model":"m","choices":[{"message":{"content":"echo cached-cmd"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
printf '0\n' >"$cfg_tmp/cache-state"
cache_env=(LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/cache-state" LMLINE_CACHE_TTL=300)
first_out=$(run_engine "${cache_env[@]}" 2>/dev/null) || fail "cache first run"
second_out=$(run_engine "${cache_env[@]}" 2>"$cfg_tmp/cache.err") || fail "cache second run"
[[ "$first_out" == "$second_out" ]] || fail "cache hit output identical"
[[ $(cat "$cfg_tmp/cache-state") == 1 ]] || fail "cache hit avoids provider request"
grep -q 'lmline-status: m=test-model; cached' "$cfg_tmp/cache.err" || fail "cache hit status"
cache_entry=$(find "$cfg_tmp/config/cache" -maxdepth 1 -type f | sed -n '1p')
[[ -n "$cache_entry" ]] || fail "cache entry exists"
# Cache storage stays private to the user: the directory is 0700 and
# entries are written under umask 077.
file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}
[[ $(file_mode "$cfg_tmp/config/cache") == 700 ]] || fail "cache directory mode"
[[ $(file_mode "$cache_entry") == 600 ]] || fail "cache entry mode"
touch -t 202001010000 "$cache_entry"
third_out=$(run_engine "${cache_env[@]}" 2>/dev/null) || fail "cache expired run"
[[ $(cat "$cfg_tmp/cache-state") == 2 ]] || fail "expired cache refetches"
[[ "$(candidates_of <<<"$third_out")" == "echo cached-cmd" ]] || fail "expired cache output"

# A symlinked cache directory must not redirect private entries: neither a
# lookup nor a store may write through the link into its target.
real_cache_dir="$cfg_tmp/config/cache-real"
link_target="$cfg_tmp/config/cache-link-target"
mv "$cfg_tmp/config/cache" "$real_cache_dir"
mkdir -p "$link_target"
ln -s "$link_target" "$cfg_tmp/config/cache"
printf '0\n' >"$cfg_tmp/cache-state"
symlink_out=$(run_engine "${cache_env[@]}" 2>/dev/null) || fail "symlinked cache engine run"
[[ "$(candidates_of <<<"$symlink_out")" == "echo cached-cmd" ]] || fail "symlinked cache output"
[[ $(cat "$cfg_tmp/cache-state") == 1 ]] || fail "symlinked cache fetched response"
[[ -z "$(find "$link_target" -mindepth 1 -print -quit)" ]] || fail "cache wrote through symlink"
rm "$cfg_tmp/config/cache"
mv "$real_cache_dir" "$cfg_tmp/config/cache"

# The lookup guard must reject the link even when it hides a fresh entry.
# Reuse the entry written by the successful run above, planting a candidate
# that can only appear if that entry is read through the symlink.
planted_entry="$cfg_tmp/config/cache/${cache_entry##*/}"
[[ -f "$planted_entry" ]] || fail "fresh cache entry for symlink lookup"
planted_file="$cfg_tmp/planted-cache-entry"
sed 's/echo cached-cmd/echo planted-cache-hit/' "$planted_entry" >"$planted_file"
cat "$planted_file" >"$planted_entry"
mv "$cfg_tmp/config/cache" "$real_cache_dir"
rmdir "$link_target"
mv "$real_cache_dir" "$link_target"
ln -s "$link_target" "$cfg_tmp/config/cache"
printf '0\n' >"$cfg_tmp/cache-state"
populated_out=$(run_engine "${cache_env[@]}" 2>/dev/null) || fail "populated symlinked cache engine run"
[[ "$(candidates_of <<<"$populated_out")" == "echo cached-cmd" ]] || fail "populated symlinked cache served planted candidate"
[[ $(cat "$cfg_tmp/cache-state") == 1 ]] || fail "populated symlinked cache fetched response"
rm "$cfg_tmp/config/cache"
mv "$link_target" "$cfg_tmp/config/cache"

# A symlinked config directory spelled with a dot component cannot hide from
# the shared private-directory guard: the planted cache entry stays unread.
cache_link="$cfg_tmp/config-dot-link"
ln -s "$cfg_tmp/config" "$cache_link"
run_engine_at() {
  env PATH="$fake_bin:$PATH" LMLINE_CONFIG_DIR="$1" \
    LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model \
    LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/cache-state" LMLINE_CACHE_TTL=300 \
    "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
    --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1
}
for dot_config in "$cache_link/." "$cache_link/./" "$cache_link/../config"; do
  printf '0\n' >"$cfg_tmp/cache-state"
  dot_out=$(run_engine_at "$dot_config" 2>/dev/null) || fail "dot-component cache engine run"
  [[ "$(candidates_of <<<"$dot_out")" == "echo cached-cmd" ]] || fail "dot-component config served a planted cache entry"
  [[ $(cat "$cfg_tmp/cache-state") == 1 ]] || fail "dot-component config did not fetch a fresh response"
done

# A relative config directory beginning with a dash must not be parsed as an
# option when the engine creates its private cache.
(
  cd "$cfg_tmp" || exit 1
  printf '0\n' >"$cfg_tmp/cache-state"
  run_engine_at -dash-config >"$cfg_tmp/dash-config.out" 2>/dev/null ||
    fail "dash-leading config engine run"
)
[[ -n "$(find "$cfg_tmp/-dash-config/cache" -maxdepth 1 -type f -print -quit)" ]] ||
  fail "dash-leading config did not create a cache entry"
[[ $(cat "$cfg_tmp/cache-state") == 1 ]] || fail "dash-leading config did not fetch a fresh response"

# Optional cache writes must not retain a partial staging file when copy or
# atomic rename fails; candidate delivery remains successful in both cases.
real_cp=$(command -v cp)
real_mv=$(command -v mv)
cat >"$fake_bin/cp" <<'EOF'
#!/usr/bin/env bash
last=
for last do :; done
if [[ "${LMLINE_FAIL_CACHE_CP:-0}" == 1 && "$last" == *".tmp."* ]]; then
  printf 'partial cache entry' >"$last"
  exit 1
fi
exec "$LMLINE_REAL_CP" "$@"
EOF
cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${LMLINE_FAIL_CACHE_MV:-0}" == 1 && "${1-}" == *".tmp."* ]]; then
  exit 1
fi
exec "$LMLINE_REAL_MV" "$@"
EOF
chmod +x "$fake_bin/cp" "$fake_bin/mv"
printf '0\n' >"$cfg_tmp/cache-copy-state"
copy_failure_out=$(run_engine LMLINE_CONFIG_DIR="$cfg_tmp/cache-copy-config" LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/cache-copy-state" LMLINE_CACHE_TTL=300 LMLINE_FAIL_CACHE_CP=1 LMLINE_REAL_CP="$real_cp" LMLINE_REAL_MV="$real_mv" 2>/dev/null) || fail "cache copy failure changed engine success"
[[ "$(candidates_of <<<"$copy_failure_out")" == "echo cached-cmd" ]] || fail "cache copy failure lost candidate"
[[ -z "$(find "$cfg_tmp/cache-copy-config/cache" -maxdepth 1 -type f -print -quit)" ]] || fail "cache copy failure retained a staging file"
printf '0\n' >"$cfg_tmp/cache-rename-state"
rename_failure_out=$(run_engine LMLINE_CONFIG_DIR="$cfg_tmp/cache-rename-config" LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/cache-rename-state" LMLINE_CACHE_TTL=300 LMLINE_FAIL_CACHE_MV=1 LMLINE_REAL_CP="$real_cp" LMLINE_REAL_MV="$real_mv" 2>/dev/null) || fail "cache rename failure changed engine success"
[[ "$(candidates_of <<<"$rename_failure_out")" == "echo cached-cmd" ]] || fail "cache rename failure lost candidate"
[[ -z "$(find "$cfg_tmp/cache-rename-config/cache" -maxdepth 1 -type f -print -quit)" ]] || fail "cache rename failure retained a staging file"
rm -f "$fake_bin/cp" "$fake_bin/mv"

# Cache hits re-apply current risk policy: permissive entry cached as low
# must serve as high after a strict policy change without refetching.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
printf '{"model":"m","choices":[{"message":{"content":"printf x | sh"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
printf '# cache policy\n' >"$cfg_tmp/policy-line"
printf '0\n' >"$cfg_tmp/policy-state"
policy_base_env=(LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/policy-state" LMLINE_CACHE_TTL=300)
policy_low_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" "${policy_base_env[@]}" LMLINE_RISK_PIPED_SHELL_LEVEL=low \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
  --line-file "$cfg_tmp/policy-line" --context-file "$cfg_tmp/context" --n 1 2>/dev/null) || fail "cache policy first run"
grep -q $'^lmline-candidate: low\t' <<<"$policy_low_out" || fail "cache policy permissive risk"
policy_high_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" "${policy_base_env[@]}" LMLINE_RISK_PIPED_SHELL_LEVEL=high \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
  --line-file "$cfg_tmp/policy-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/policy.err") || fail "cache policy second run"
grep -q $'^lmline-candidate: high\t' <<<"$policy_high_out" || fail "cache policy strict reclassification"
[[ $(cat "$cfg_tmp/policy-state") == 1 ]] || fail "cache policy hit avoids refetch"
grep -q 'lmline-status: m=test-model; cached' "$cfg_tmp/policy.err" || fail "cache policy hit status"

# A fully stale cache entry must not emit its cached status before refetching:
# the refetch owns the single status line.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
printf '{"model":"m","choices":[{"message":{"content":"echo fresh-cmd"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
printf '# stale status\n' >"$cfg_tmp/stale-line"
printf '0\n' >"$cfg_tmp/stale-state"
mkdir -p "$cfg_tmp/stale-config"
stale_engine_env=(LMLINE_CONFIG_DIR="$cfg_tmp/stale-config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model)
stale_base_env=(LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/stale-state" LMLINE_CACHE_TTL=300)
env PATH="$fake_bin:$PATH" "${stale_engine_env[@]}" "${stale_base_env[@]}" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
  --line-file "$cfg_tmp/stale-line" --context-file "$cfg_tmp/context" --n 1 >/dev/null 2>/dev/null || fail "stale cache first run"
stale_entry=$(find "$cfg_tmp/stale-config/cache" -maxdepth 1 -type f | sed -n '1p')
[[ -n "$stale_entry" ]] || fail "stale cache entry exists"
printf 'lmline-candidate: low\ttest\t-\t```\n' >"$stale_entry"
stale_out=$(env PATH="$fake_bin:$PATH" "${stale_engine_env[@]}" "${stale_base_env[@]}" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
  --line-file "$cfg_tmp/stale-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/stale.err") || fail "stale cache second run"
[[ $(cat "$cfg_tmp/stale-state") == 2 ]] || fail "stale cache refetches"
[[ "$(candidates_of <<<"$stale_out")" == "echo fresh-cmd" ]] || fail "stale cache fresh output"
[[ $(grep -c '^lmline-status:' "$cfg_tmp/stale.err") == 1 ]] || fail "stale cache single status"
[[ $(grep -c '^lmline-meta:' "$cfg_tmp/stale.err") == 1 ]] || fail "stale cache single meta"

# The declared working directory is part of the engine cache identity: the same
# line from a fixed launching directory with different --cwd values must not collide.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
if (( count == 1 )); then
  printf '{"model":"m","choices":[{"message":{"content":"echo project-a"},"finish_reason":"stop"}]}' >"$out"
else
  printf '{"model":"m","choices":[{"message":{"content":"echo project-b"},"finish_reason":"stop"}]}' >"$out"
fi
printf '200\tapplication/json'
EOF
printf '# deploy\n' >"$cfg_tmp/cwd-line"
printf '0\n' >"$cfg_tmp/cwd-state"
mkdir -p "$cfg_tmp/cwd-config"
cwd_engine_env=(LMLINE_CONFIG_DIR="$cfg_tmp/cwd-config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model)
cwd_base_env=(LMLINE_TOOL_MODE=none LMLINE_FAKE_CURL_STATE="$cfg_tmp/cwd-state" LMLINE_CACHE_TTL=300)
cwd_a_out=$(env PATH="$fake_bin:$PATH" "${cwd_engine_env[@]}" "${cwd_base_env[@]}" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd /work/project-a --point 0 \
  --line-file "$cfg_tmp/cwd-line" --context-file "$cfg_tmp/context" --n 1 2>/dev/null) || fail "cwd cache first run"
[[ "$(candidates_of <<<"$cwd_a_out")" == "echo project-a" ]] || fail "cwd cache first output"
cwd_b_out=$(env PATH="$fake_bin:$PATH" "${cwd_engine_env[@]}" "${cwd_base_env[@]}" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd /work/project-b --point 0 \
  --line-file "$cfg_tmp/cwd-line" --context-file "$cfg_tmp/context" --n 1 2>/dev/null) || fail "cwd cache second run"
[[ "$(candidates_of <<<"$cwd_b_out")" == "echo project-b" ]] || fail "cwd cache distinct directory output"
[[ $(cat "$cfg_tmp/cwd-state") == 2 ]] || fail "cwd cache distinct directory refetches"
cwd_b_hit=$(env PATH="$fake_bin:$PATH" "${cwd_engine_env[@]}" "${cwd_base_env[@]}" \
  "$repo_dir/lmline/engine" --mode generate --shell bash --cwd /work/project-b --point 0 \
  --line-file "$cfg_tmp/cwd-line" --context-file "$cfg_tmp/context" --n 1 2>/dev/null) || fail "cwd cache hit run"
[[ "$(candidates_of <<<"$cwd_b_hit")" == "echo project-b" ]] || fail "cwd cache hit output"
[[ $(cat "$cfg_tmp/cwd-state") == 2 ]] || fail "cwd cache same directory hits"

# fix depends on captured execution output and clip on clipboard content;
# neither input is in the cache key, so both modes must ask the provider every
# time even when a cache TTL is set.
uncached_bin="$cfg_tmp/uncached-bin"
mkdir -p "$uncached_bin" "$cfg_tmp/uncached-config"
cat >"$uncached_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
printf '{"model":"m","choices":[{"message":{"content":"echo unchanged"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
chmod +x "$uncached_bin/curl"
uncached_env=(LMLINE_CONFIG_DIR="$cfg_tmp/uncached-config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model LMLINE_TOOL_MODE=none LMLINE_CACHE_TTL=300)
for uncached_mode in fix clip; do
  # Plain clip answers can be emitted from cache; annotated clip answers
  # cannot, which would make a cache hit fail for unrelated reasons.
  uncached_format=annotated
  [[ "$uncached_mode" == clip ]] && uncached_format=plain
  printf '0\n' >"$cfg_tmp/uncached-state"
  for pass in 1 2; do
    env PATH="$uncached_bin:$PATH" "${uncached_env[@]}" LMLINE_FAKE_CURL_STATE="$cfg_tmp/uncached-state" \
      "$repo_dir/lmline/engine" --mode "$uncached_mode" --format "$uncached_format" \
        --shell bash --cwd "$repo_dir" --point 0 \
      --line-file "$cfg_tmp/line" --context-file "$cfg_tmp/context" --n 1 \
      >"$cfg_tmp/uncached-$uncached_mode-$pass.out" 2>"$cfg_tmp/uncached-$uncached_mode-$pass.err" \
      || fail "$uncached_mode engine run $pass"
  done
  [[ "$(cat "$cfg_tmp/uncached-state")" == 2 ]] || fail "$uncached_mode served a cached answer"
  ! grep -q 'tokens=cached' "$cfg_tmp/uncached-$uncached_mode-2.err" || fail "$uncached_mode reported a cache hit"
done
ok "fix and clip never use cached answers"

# --- streaming (explain, tool mode none) -------------------------------------
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"<think>\n"}}]}'
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"secret reasoning\n</think>\nstreamed "}}]}'
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"explanation line\nsecond line"}}]}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
echo "unexpected non-stream request" >&2
exit 9
EOF
printf 'echo hi\n' >"$cfg_tmp/explain-line"
stream_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/stream.err") || fail "stream engine run"
[[ "$stream_out" == $'streamed explanation line\nsecond line' ]] || fail "stream output"
! grep -q 'secret reasoning' <<<"$stream_out" || fail "stream think stripping"
grep -q '^lmline-status: ' "$cfg_tmp/stream.err" || fail "stream status line"

# Stream with no content falls back to the buffered request.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
out=
while (($#)); do
  case "$1" in
    -N) is_stream=1; shift ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
if (( is_stream )); then
  printf 'data: [DONE]\n\n'
  exit 0
fi
printf '{"choices":[{"message":{"content":"buffered fallback"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
fallback_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/fallback.err") || fail "stream fallback run"
[[ "$fallback_out" == "buffered fallback" ]] || fail "stream fallback output"
grep -q 'streaming unavailable; continuing with a buffered request' "$cfg_tmp/fallback.err" || fail "stream fallback progress"

# Streamed usage chunk (stream_options.include_usage) fills the status line.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"usage answer\n"}}]}'
  printf '%s\n\n' 'data: {"model":"usage-model","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
echo "unexpected non-stream request" >&2
exit 9
EOF
usage_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/usage.err") || fail "stream usage run"
[[ "$usage_out" == "usage answer" ]] || fail "stream usage output"
grep -q 'lmline-status: m=usage-model; tok=7/3/10' "$cfg_tmp/usage.err" || fail "stream usage status tokens"

# Streamed output respects the explain byte budget and emits a marker.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"first line ok\nsecond line is far beyond the byte budget\nthird line too\n"}}]}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
echo "unexpected non-stream request" >&2
exit 9
EOF
limit_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=none LMLINE_STREAM=1 LMLINE_EXPLAIN_MAX_OUTPUT_BYTES=20 \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>/dev/null) || fail "stream limit run"
grep -q '^first line ok$' <<<"$limit_out" || fail "stream limit kept first line"
! grep -q 'second line' <<<"$limit_out" || fail "stream limit dropped over-budget line"
grep -q 'explanation-truncated original_bytes=.* max_bytes=20' <<<"$limit_out" || fail "stream limit marker"

# Streaming drives the tool loop: a native tool-call round runs locally and
# the final answer still streams.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
for a in "$@"; do [[ "$a" == "-N" ]] && is_stream=1; done
(( is_stream )) || { echo "unexpected non-stream request" >&2; exit 9; }
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
if (( count == 1 )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"command_exists","arguments":""}}]}}]}'
  printf '%s\n\n' 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"commands\":\"awk\"}"}}]}}]}'
  printf 'data: [DONE]\n\n'
else
  printf '%s\n\n' 'data: {"choices":[{"delta":{"content":"tool-informed answer\n"}}]}'
  printf 'data: [DONE]\n\n'
fi
exit 0
EOF
printf '0\n' >"$cfg_tmp/stream-tool-state"
stream_tool_out=$(env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=openai LMLINE_STREAM=1 \
  LMLINE_FAKE_CURL_STATE="$cfg_tmp/stream-tool-state" \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 2>"$cfg_tmp/stream-tool.err") || fail "stream tool run"
[[ "$stream_tool_out" == "tool-informed answer" ]] || fail "stream tool final output"
[[ $(cat "$cfg_tmp/stream-tool-state") == 2 ]] || fail "stream tool round count"
grep -q 'lmline-progress: tool command-exists (openai, round 1/4)' "$cfg_tmp/stream-tool.err" || fail "stream tool progress"
grep -q 'lmline-status: .*tools=command-exists' "$cfg_tmp/stream-tool.err" || fail "stream tool status"

# A failed streamed tool round is fatal, not a reason to issue a buffered
# request that could repeat tool side effects.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
is_stream=0
out=
while (($#)); do
  case "$1" in
    -N) is_stream=1; shift ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
state=${LMLINE_FAKE_CURL_STATE:?}
count=0; [[ -f "$state" ]] && read -r count <"$state"
count=$((count + 1)); printf '%s\n' "$count" >"$state"
if (( is_stream )); then
  printf '%s\n\n' 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"command_exists","arguments":"{\"commands\":\"ls\"}"}}]}}]}'
  printf 'data: [DONE]\n\n'
  exit 0
fi
printf '%s' '{"choices":[{"message":{"content":"buffered fallback must not run"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
failed_tool_state="$cfg_tmp/failed-stream-tool-state"
printf '0\n' >"$failed_tool_state"
missing_patterns="$cfg_tmp/missing-condense-patterns.txt"
if env PATH="$fake_bin:$PATH" "${engine_env[@]}" LMLINE_TOOL_MODE=openai LMLINE_STREAM=1 \
  LMLINE_FAKE_CURL_STATE="$failed_tool_state" LMLINE_CONDENSE_PATTERNS_FILE="$missing_patterns" \
  "$repo_dir/lmline/engine" --mode explain --shell bash --cwd "$repo_dir" --point 7 \
  --line-file "$cfg_tmp/explain-line" --context-file "$cfg_tmp/context" --n 1 \
  >"$cfg_tmp/failed-stream-tool.out" 2>"$cfg_tmp/failed-stream-tool.err"; then
  fail "failed streamed tool round must exit nonzero"
fi
[[ $(cat "$failed_tool_state") == 1 ]] || fail "failed streamed tool round makes no fallback request"
grep -Fq "lmline: condense_priority_patterns file is not readable: $missing_patterns" \
  "$cfg_tmp/failed-stream-tool.err" || fail "failed streamed tool resolver diagnostic"
! grep -q 'buffered fallback must not run' "$cfg_tmp/failed-stream-tool.out" || \
  fail "failed streamed tool round does not emit buffered response"

# --- endpoint/model CRUD and use auto-select ---------------------------------
crud_dir="$cfg_tmp/crud"
lm() { LMLINE_CONFIG_DIR="$crud_dir" "$repo_dir/lmline/lmline" "$@"; }
lm endpoint add ep https://crud.example/v1 >/dev/null
lm endpoint set-secret ep crud-secret 2>"$cfg_tmp/secret-warn.err" >/dev/null
grep -q 'leak via shell history' "$cfg_tmp/secret-warn.err" || fail "set-secret argv warning"
lm model add ep solo-model >/dev/null
lm use ep >/dev/null || fail "use auto-select single model"
grep -q "LMLINE_MODEL=.*solo-model" "$crud_dir/settings.bash" || fail "use auto-select persisted"
lm model add ep second-model >/dev/null
if lm use ep >/dev/null 2>"$cfg_tmp/use-multi.err"; then
  fail "use with multiple models must fail"
fi
grep -q 'lmline use ep solo-model' "$cfg_tmp/use-multi.err" || fail "use multi hint"
lm model remove ep second-model || fail "model remove"
! lm model list ep | grep -q second-model || fail "model removed from list"
secret_path=$(awk -F '\t' '$1 == "ep" { print $5 }' "$crud_dir/endpoints.tsv")
[[ -f "$secret_path" ]] || fail "secret exists before endpoint remove"
lm endpoint remove ep 2>/dev/null || fail "endpoint remove"
[[ ! -f "$secret_path" ]] || fail "endpoint remove deletes secret"
! lm endpoint list | grep -q '^ep' || fail "endpoint removed from list"
[[ -z "$(lm model list ep)" ]] || fail "endpoint remove drops models"

# config set accepts an explicitly empty value (raw-header auth scheme).
lm config set LMLINE_AUTH_SCHEME '' || fail "config set empty value"
grep -q "^export LMLINE_AUTH_SCHEME=''" "$crud_dir/settings.bash" || fail "empty value persisted"
if lm config set LMLINE_AUTH_SCHEME >/dev/null 2>&1; then
  fail "config set without value must fail"
fi

# --- risk normalization --------------------------------------------------------
risk_of() { LMLINE_CONFIG_DIR="$crud_dir" "$repo_dir/lmline/lmline" risk "$1" | sed -n 's/^risk=//p'; }
[[ $(risk_of 'dd if=/dev/zero of=/dev/null') == high ]] || fail "risk dd at line start"
[[ $(risk_of 'dd') == high ]] || fail "risk bare dd"
[[ $(risk_of 'cat f | dd of=/dev/null') == high ]] || fail "risk dd mid-pipeline"
[[ $(risk_of 'mkfs.ext4 /dev/sda1') == high ]] || fail "risk mkfs at line start"
[[ $(risk_of 'sudo ls') == high ]] || fail "risk sudo at line start"
[[ $(risk_of 'echo dde') == low ]] || fail "risk no false positive on substring"

# The shared traversal check keeps ordinary relative prefixes usable and
# rejects only dot components after a named component.
# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
for path in ./traces ../traces /tmp/traces /tmp/traces/; do
  ! __lmline_path_has_traversal_after_component "$path" || fail "shared helper rejected a normal path: $path"
done
for path in /tmp/link/. /tmp/link/./ /tmp/link/../target ./link/../target; do
  __lmline_path_has_traversal_after_component "$path" || fail "shared helper accepted a dot component: $path"
done

# The shared helper returns a safe mktemp operand without owning TMPDIR.
[[ $(TMPDIR=/var/tmp __lmline_tmp_root) == /var/tmp ]] ||
  fail "temp root changed an absolute TMPDIR"
original_tmpdir=${TMPDIR-}
[[ $(TMPDIR=-tmp __lmline_tmp_root) == ./-tmp ]] ||
  fail "temp root did not prefix a dash-leading TMPDIR"
[[ ${TMPDIR-} == "$original_tmpdir" ]] || fail "temp root rewrote the caller TMPDIR"
[[ $(TMPDIR=relative __lmline_tmp_root) == ./relative ]] ||
  fail "temp root did not prefix a relative TMPDIR"
[[ $(TMPDIR= __lmline_tmp_root) == /tmp ]] ||
  fail "temp root lost the default directory"

# A dash-leading relative TMPDIR stays the caller's own value; lmline turns it
# into a safe, cwd-relative mktemp operand instead of rewriting the variable.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($#)); do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
printf '%s' '{"model":"m","choices":[{"message":{"content":"echo tmpdir-ok"},"finish_reason":"stop"}]}' >"$out"
printf '200\tapplication/json'
EOF
# Log both the operand and the absolute path it resolves to. The real mktemp
# must stay explicit: calling "mktemp" here would recurse through this shim.
cat >"$fake_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
for last do :; done
case $last in
  /*) abs=$last ;;
  */*) abs=$(cd -- "${last%/*}" && printf '%s/%s\n' "$PWD" "${last##*/}") ;;
  *) abs=$PWD/$last ;;
esac
printf '%s\t%s\n' "$last" "$abs" >>"$LMLINE_MKTEMP_LOG"
exec "$LMLINE_REAL_MKTEMP" "$@"
EOF
chmod +x "$fake_bin/mktemp"
real_mktemp=$(command -v mktemp)
mkdir -m 700 -- "$cfg_tmp/-tmp"
: >"$cfg_tmp/mktemp.log"
(
  cd "$cfg_tmp" || exit 1
  if run_engine LMLINE_TOOL_MODE=none \
    TMPDIR=-tmp LMLINE_MKTEMP_LOG="$cfg_tmp/mktemp.log" \
    LMLINE_REAL_MKTEMP="$real_mktemp" >"$cfg_tmp/tmpdir.out" 2>"$cfg_tmp/tmpdir.err"
  then
    :
  else
    cat "$cfg_tmp/tmpdir.out" "$cfg_tmp/tmpdir.err" >&2
    fail "engine run with dash-leading TMPDIR"
  fi
)
cut -f1 "$cfg_tmp/mktemp.log" | grep -q '^\./-tmp/lmline-' ||
  fail "engine did not pass a safe mktemp operand"
cut -f2 "$cfg_tmp/mktemp.log" | grep -q "^$cfg_tmp/-tmp/lmline-" ||
  fail "engine did not use the configured dash-leading TMPDIR"
! cut -f1 "$cfg_tmp/mktemp.log" | grep -q '^-' ||
  fail "mktemp reinterpreted a dash-leading TMPDIR as options"
ok "engine uses a dash-leading relative TMPDIR"

: >"$cfg_tmp/mktemp.log"
(
  cd "$cfg_tmp" || exit 1
  PATH="$fake_bin:$PATH" TMPDIR=-tmp \
    LMLINE_MKTEMP_LOG="$cfg_tmp/mktemp.log" \
    LMLINE_REAL_MKTEMP="$real_mktemp" \
    LMLINE_CONFIG_DIR="$crud_dir" "$repo_dir/lmline/lmline" \
    config set LMLINE_DEBUG 1 >/dev/null 2>&1 || fail "CLI run with dash-leading TMPDIR"
)
cut -f1 "$cfg_tmp/mktemp.log" | grep -q '^\./-tmp/lmline-cfg' ||
  fail "CLI did not pass a safe mktemp operand"
cut -f2 "$cfg_tmp/mktemp.log" | grep -q "^$cfg_tmp/-tmp/lmline-cfg" ||
  fail "CLI did not use the configured dash-leading TMPDIR"
ok "CLI uses a dash-leading relative TMPDIR"

# Mirrors the Bash subprocess the zsh bridge starts with context/actions sourced.
cat >"$cfg_tmp/probe_helper.sh" <<'EOF'
#!/usr/bin/env bash
source "$1/context.bash"
source "$1/actions.bash"
__lmline_probe_command echo --version >/dev/null
EOF
chmod +x "$cfg_tmp/probe_helper.sh"
for shell in bash zsh; do
  shell_flags=(-f -e -i)
  [[ $shell != bash ]] || shell_flags=(--norc -e -i)
  workspace="$cfg_tmp/workspace-$shell"
  mkdir -p "$workspace/-tmp" "$workspace/nested/-tmp"
  chmod 700 "$workspace/-tmp" "$workspace/nested/-tmp"
  : >"$cfg_tmp/mktemp.log"
  shell_state=$(
    cd "$workspace" || exit 1
    PATH="$fake_bin:$PATH" TMPDIR=-tmp LMLINE_BIND_KEYS=0 \
      LMLINE_MKTEMP_LOG="$cfg_tmp/mktemp.log" \
      LMLINE_REAL_MKTEMP="$real_mktemp" \
      "$shell" "${shell_flags[@]}" -c '
        source "$1" || exit 1
        printf "TMPDIR=%s\n" "$TMPDIR"
        cd nested || exit 1
        "$2" "$3" || exit 1
      ' _ "$repo_dir/lmline/init.$shell" "$cfg_tmp/probe_helper.sh" "$repo_dir/lmline" 2>/dev/null
  ) || fail "$shell integration failed with dash-leading TMPDIR"
  [[ $shell_state == 'TMPDIR=-tmp' ]] ||
    fail "$shell integration rewrote the caller's TMPDIR: $shell_state"
  cut -f1 "$cfg_tmp/mktemp.log" | grep -q '^\./-tmp/lmline-probe' ||
    fail "$shell temp path is not a safe mktemp operand after cd"
  cut -f2 "$cfg_tmp/mktemp.log" | grep -q "^$workspace/nested/-tmp/lmline-probe" ||
    fail "$shell temp file did not land under the workspace -tmp directory after cd"
  ok "$shell integration keeps TMPDIR and lands temp files in the workspace dir"
done

ok "features (protocol, retry, cache, stream, crud, risk)"
