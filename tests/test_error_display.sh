#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: decoded provider errors reach terminals, or display filtering changes
# raw classification, byte budgets, trusted framing, or engine failure status.
# All assertions are boolean-only; never print fixtures or captured output.
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/actions.bash
source "$repo_dir/lmline/actions.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"
work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-error-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
export LMLINE_AUTH_MODE=api-key LMLINE_TRACE_DIR=

# A payload preview exercises request and metadata tracing without a provider.
trace_preview() (
  umask 022
  LMLINE_CONFIG_DIR="$work/config" LMLINE_BASE_URL=https://api.test.invalid/v1 LMLINE_MODEL=test-model \
    "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" --point 0 \
    --line-file "$work/trace-line" --context-file "$work/trace-context" --n 1 --dry-run-payload
)
printf '# synthetic-trace-prompt\n' >"$work/trace-line"
: >"$work/trace-context"
trace_preview >"$work/trace-off.out" 2>"$work/trace-off.err" || fail 'trace preview baseline'
mkdir -m 0755 "$work/public-trace" "$work/trace-bin"
cat >"$work/trace-bin/chmod" <<'EOF'
#!/usr/bin/env bash
printf 'synthetic chmod output\n'
printf 'synthetic chmod diagnostic\n' >&2
exit "${LMLINE_TEST_CHMOD_STATUS:?}"
EOF
chmod +x "$work/trace-bin/chmod"
# Both a failed chmod and a successful no-op must leave a public directory empty.
for chmod_status in 1 0; do
  LMLINE_TRACE_DIR="$work/public-trace" PATH="$work/trace-bin:$PATH" LMLINE_TEST_CHMOD_STATUS=$chmod_status \
    trace_preview >"$work/trace.out" 2>"$work/trace.err" || fail 'blocked trace changed engine exit status'
  [[ -z $(ls -A "$work/public-trace") ]] || fail "trace was written to a public directory with chmod status $chmod_status"
  cmp -s "$work/trace-off.out" "$work/trace.out" && cmp -s "$work/trace-off.err" "$work/trace.err" \
    || fail 'blocked trace changed engine output or diagnostics'
done
# A new destination must be private even without chmod actually changing it.
private_trace="$work/private/trace"
LMLINE_TRACE_DIR="$private_trace" PATH="$work/trace-bin:$PATH" LMLINE_TEST_CHMOD_STATUS=0 \
  trace_preview >"$work/trace.out" 2>"$work/trace.err" || fail 'private trace changed engine exit status'
[[ $(stat -c %a "$private_trace" 2>/dev/null || stat -f %Lp "$private_trace") == 700 ]] || fail 'new trace directory is not mode 0700'
jq . "$private_trace"/*.request.json | cmp -s "$work/trace-off.out" - || fail 'private request trace does not match payload'
grep -Fq 'synthetic-trace-prompt' "$private_trace"/*.meta || fail 'private metadata trace is missing the synthetic prompt'
cmp -s "$work/trace-off.out" "$work/trace.out" && cmp -s "$work/trace-off.err" "$work/trace.err" \
  || fail 'private trace changed engine output or diagnostics'

# A symlink must never be chmodded or written through, even when its real
# target is already private; trailing slashes must not hide the symlink.
trace_symlink="$work/trace-symlink"
trace_target="$work/trace-target"
mkdir -m 0700 "$trace_target"
ln -s "$trace_target" "$trace_symlink"
target_mode=$(stat -c %a "$trace_target" 2>/dev/null || stat -f %Lp "$trace_target")
for trace_dir in "$trace_symlink" "$trace_symlink/" "$trace_symlink///"; do
  LMLINE_TRACE_DIR="$trace_dir" PATH="$work/trace-bin:$PATH" LMLINE_TEST_CHMOD_STATUS=0 \
    trace_preview >"$work/trace.out" 2>"$work/trace.err" || fail 'symlinked trace changed engine exit status'
  [[ -L "$trace_symlink" ]] || fail 'trace directory symlink was replaced'
  [[ $(readlink "$trace_symlink") == "$trace_target" ]] || fail 'trace directory symlink target changed'
  [[ -z $(ls -A "$trace_target") ]] || fail "trace was written through a symlinked directory: $trace_dir"
  [[ $(stat -c %a "$trace_target" 2>/dev/null || stat -f %Lp "$trace_target") == "$target_mode" ]] \
    || fail "symlink target mode changed: $trace_dir"
  cmp -s "$work/trace-off.out" "$work/trace.out" && cmp -s "$work/trace-off.err" "$work/trace.err" \
    || fail "symlinked trace changed engine output or diagnostics: $trace_dir"
done
ok 'symlinked trace directories are refused'

fixture=$work/error.json
hint='; full error: lmline debug trace on'
prefix=$'\e[32m[lm]\e[0m '
plain=$'שלום مرحبا ASCII [brackets] \\ slash UTF-8: \303\251 \346\227\245 \360\237\230\200'

# Actual JSON decoding includes message, code and param, not escaped JSON text.
for sequence in $'\e]52;c;payload\a' $'\e[2J' $'\ePpayload\e\\' \
  $'\302\235payload\302\234' $'\302\2332J' $'\001\177\302\205' \
  $'\330\234\342\200\256\342\201\246'; do
  raw="left${sequence}right $plain"
  jq -cn --arg message "$raw" --arg code "bad${sequence}code" --arg param "a${sequence}b" \
    '{error:{message:$message,code:$code,param:$param}}' >"$fixture"
  detail=$(__lmline_response_error_detail "$fixture" application/json)
  [[ "$detail" == "bad${sequence}code (param=a${sequence}b): $raw" ]] || fail 'raw provider detail retained'
  __lmline_report_request_failure 422 application/json "$fixture" 2>"$work/direct"
  expected="lmline-engine: request failed: HTTP 422: badcode (param=ab): leftright $plain$hint"
  [[ $(cat "$work/direct") == "$expected" ]] || fail 'decoded provider detail sanitized and ordinary UTF-8 preserved'
  out=$(__lmline_engine_error_message "$prefix" "$raw")
  [[ "$out" == "${prefix}engine failed: leftright $plain (try: lmline doctor --check-api)" ]] || fail 'frontend error detail sanitized without changing trusted prefix'
done
out=$(__lmline_engine_error_message "$prefix" "lmline-engine: no valid candidate: $raw")
[[ "$out" == "${prefix}no valid candidate: leftright $plain" ]] || fail 'candidate failure detail sanitized'

# Preserve existing one-line formatting and cap raw bytes BEFORE rendering:
# five bytes of CSI consume budget, so stripping must not backfill them.
printf -v padding '%*s' 400 ''
padding=${padding// /x}
jq -cn --arg message $'\e[31m'"$padding" '{error:{message:$message}}' >"$fixture"
__lmline_report_request_failure 422 application/json "$fixture" 2>"$work/direct"
[[ $(cat "$work/direct") == "lmline-engine: request failed: HTTP 422: ${padding:0:395}...$hint" ]] || fail 'raw byte cap precedes sanitization'
jq -cn --arg message "$plain"$'\nsecond\tline' '{error:{message:$message}}' >"$fixture"
__lmline_report_request_failure 422 application/json "$fixture" 2>"$work/direct"
[[ $(cat "$work/direct") == "lmline-engine: request failed: HTTP 422: $plain secondline$hint" ]] || fail 'single-line text retained and tab removed'

# Classification still sees raw text: removing a control string must not join
# a new store-field match; a hidden auth keyword must still select auth advice.
jq -cn --arg message $'Unrecognized st\e]0;title\aore field' '{error:{message:$message}}' >"$fixture"
__lmline_report_request_failure 400 application/json "$fixture" 2>"$work/direct"
[[ $(cat "$work/direct") == "lmline-engine: request failed: HTTP 400: Unrecognized store field$hint" ]] || fail 'provider hint classification stays raw'
out=$(__lmline_engine_error_message "$prefix" $'left\e]0;401\aright')
[[ "$out" == "${prefix}auth failed; try: lmline endpoint set-secret ENDPOINT (check: lmline config get)" ]] || fail 'engine classification stays raw'

# Both buffered frontends and their streaming branch must sanitize a failing
# engine too (including engines that have not rendered their own stderr).
export LMLINE_ERROR_FIXTURE=$fixture
jq -cn --arg message "left"$'\e]52;c;payload\a\e[2J'"right $plain" '{error:{message:$message}}' >"$fixture"
cat >"$work/engine" <<'ENGINE'
#!/usr/bin/env bash
jq -r '.error.message' "$LMLINE_ERROR_FIXTURE" >&2
exit 23
ENGINE
chmod +x "$work/engine"
# Isolate context/clipboard collection from terminal error presentation.
__lmline_context_file() { : >"$1"; }
__lmline_risk_match() { printf 'low\ttest\n'; }
__lmline_collect_command_summaries() { :; }
__lmline_clipboard_read() { printf 'clipboard'; }
# shellcheck disable=SC2031
before_options=$- before_set=$(set +o) before_shopt=$(shopt -p) before_locale=$LC_ALL
for stream in 0 1; do
  for action in explain clip; do
    status=0
    if [[ "$action" == explain ]]; then
      LMLINE_STREAM=$stream __lmline_print_explanation "$work/engine" bash 'echo hi' 7 "$prefix" >"$work/frontend" 2>&1 || status=$?
    else
      LMLINE_STREAM=$stream __lmline_print_clip "$work/engine" bash 'question' "$prefix" >"$work/frontend" 2>&1 || status=$?
    fi
    [[ "$status" == 23 ]] || fail 'frontend engine error status preserved'
    [[ $(tail -n 1 "$work/frontend") == "${prefix}engine failed: leftright $plain (try: lmline doctor --check-api)" ]] || fail 'buffered and streaming frontend errors sanitized'
    # shellcheck disable=SC2031
    [[ "$-" == "$before_options" && "$(set +o)" == "$before_set" && "$(shopt -p)" == "$before_shopt" && "$LC_ALL" == "$before_locale" ]] || fail 'caller state preserved'
  done
done

# Response IDs share the terminal-safe one-line display boundary with provider
# details; RTL letters survive, while OSC, bidi controls and newline do not.
response_id=$'r-test\342\200\256\e]52;c;synthetic\a\nforged-שלום-مرحبا'
jq -cn --arg id "$response_id" --arg message 'provider failure' \
  '{id:$id,status:"failed",error:{message:$message}}' >"$fixture"
__lmline_report_provider_failure "$fixture" 2>"$work/id-detail"
expected="lmline-engine: request failed: provider failure (response r-test forged-שלום-مرحبا)$hint"
[[ $(cat "$work/id-detail") == "$expected" ]] || fail 'response ID sanitized in provider-detail branch'
[[ $(wc -l <"$work/id-detail") -eq 1 ]] || fail 'response ID newline collapsed'
! grep -Fq $'\e]52;c;synthetic\a' "$work/id-detail" || fail 'response ID OSC removed'
jq -e --arg id "$response_id" '.id == $id' "$fixture" >/dev/null || fail 'raw response ID retained'

# Exercise the reporter's no-detail branch as well: extraction remains
# separate from the terminal-facing response ID.
(
  __lmline_response_error_detail() { :; }
  __lmline_report_provider_failure "$fixture" 2>"$work/id-no-detail"
)
expected="lmline-engine: request failed: provider reported a failed response (response r-test forged-שלום-مرحبا)$hint"
[[ $(cat "$work/id-no-detail") == "$expected" ]] || fail 'response ID sanitized in no-detail branch'
[[ $(wc -l <"$work/id-no-detail") -eq 1 ]] || fail 'no-detail response ID newline collapsed'
! grep -Fq $'\e]52;c;synthetic\a' "$work/id-no-detail" || fail 'no-detail response ID OSC removed'

# Missing or failed renderers never fall back to raw text, even if a failed
# renderer emitted a partial unsafe result. Trusted hints remain available.
for renderer in missing failed; do
  unset -f __lmline_display_answer
  if [[ "$renderer" == failed ]]; then
    __lmline_display_answer() { cat; return 43; }
  fi
  out=$(__lmline_engine_error_message "$prefix" "$raw" 2>"$work/renderer.stderr")
  [[ "$out" == "${prefix}engine failed:  (try: lmline doctor --check-api)" ]] || fail 'engine error fails closed without renderer'
  [[ ! -s "$work/renderer.stderr" ]] || fail 'engine error renderer failure emits no pipe diagnostics'
  out=$(__lmline_engine_error_message "$prefix" "lmline-engine: no valid candidate: $raw" 2>"$work/renderer.stderr")
  [[ "$out" == "$prefix" ]] || fail 'candidate error fails closed without renderer'
  [[ ! -s "$work/renderer.stderr" ]] || fail 'candidate error renderer failure emits no pipe diagnostics'
  __lmline_report_request_failure 422 application/json "$fixture" 2>"$work/direct"
  actual=$(cat "$work/direct")
  expected="lmline-engine: request failed: HTTP 422: $hint"
  if [[ "$actual" != "$expected" ]]; then
    header=no hint_present=no provider_marker=no
    [[ "$actual" == 'lmline-engine: request failed: HTTP 422: '* ]] && header=yes
    [[ "$actual" == *"$hint" ]] && hint_present=yes
    [[ "$actual" == *left* || "$actual" == *right* || "$actual" == *payload* ]] && provider_marker=yes
    fail "provider error fails closed without renderer (renderer=$renderer; header=$header; hint=$hint_present; provider_marker=$provider_marker)"
  fi

  jq -cn --arg id "$response_id" --arg message "$raw" '{id:$id,error:{message:$message},status:"failed"}' >"$fixture"
  __lmline_report_provider_failure "$fixture" 2>"$work/direct"
  actual=$(cat "$work/direct")
  expected="lmline-engine: request failed: $hint"
  [[ "$actual" == "$expected" ]] || fail 'streamed provider error fails closed without renderer diagnostics or raw ID'
  (
    # This replacement is called indirectly by the provider-failure reporter.
    # shellcheck disable=SC2329
    __lmline_response_error_detail() { :; }
    __lmline_report_provider_failure "$fixture" 2>"$work/no-detail-renderer"
  )
  expected="lmline-engine: request failed: provider reported a failed response$hint"
  [[ $(cat "$work/no-detail-renderer") == "$expected" ]] || fail 'no-detail provider error fails closed without renderer or raw ID'
done
ok 'terminal-safe provider error display'
