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
fixture=$work/error.json
hint='; full error: lmline debug trace on'
prefix=$'\e[32m[lm]\e[0m '
plain=$'ASCII [brackets] \\ slash UTF-8: \303\251 \346\227\245 \360\237\230\200'

# Actual JSON decoding includes message, code and param, not escaped JSON text.
for sequence in $'\e]52;c;payload\a' $'\e[2J' $'\ePpayload\e\\' \
  $'\302\235payload\302\234' $'\302\2332J' $'\001\177\302\205'; do
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

# Missing or failed renderers never fall back to raw text, even if a failed
# renderer emitted a partial unsafe result. Trusted hints remain available.
for renderer in missing failed; do
  unset -f __lmline_display_answer
  if [[ "$renderer" == failed ]]; then
    __lmline_display_answer() { cat; return 43; }
  fi
  out=$(__lmline_engine_error_message "$prefix" "$raw")
  [[ "$out" == "${prefix}engine failed:  (try: lmline doctor --check-api)" ]] || fail 'engine error fails closed without renderer'
  out=$(__lmline_engine_error_message "$prefix" "lmline-engine: no valid candidate: $raw")
  [[ "$out" == "$prefix" ]] || fail 'candidate error fails closed without renderer'
  __lmline_report_request_failure 422 application/json "$fixture" 2>"$work/direct"
  [[ $(cat "$work/direct") == "lmline-engine: request failed: HTTP 422: $hint" ]] || fail 'provider error fails closed without renderer'
done
ok 'terminal-safe provider error display'
