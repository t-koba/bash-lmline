#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"
work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-model-display-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

usage_file=$work/usage.tsv
tools_file=$work/tools
rejected_file=$work/rejected
: >"$usage_file"
: >"$tools_file"
LMLINE_MODEL=fallback-model
start_time=1
__lmline_elapsed_seconds() { printf '5'; }

raw_model=$'provider\e]52;c;payload\a model\t900\t800\t700\ninjected'
jq -cn --arg model "$raw_model" \
  '{model:$model,usage:{prompt_tokens:1,completion_tokens:2,total_tokens:3}}' >"$work/response.json"
cp "$work/response.json" "$work/response.original"
LMLINE_TRACE_DIR=$work/trace
trace_id=fixture
__lmline_trace_file response "$work/response.json"
__lmline_record_usage "$work/response.json"

[[ $(wc -l <"$usage_file" | tr -d ' ') == 1 ]] || fail 'provider model delimiters remain inside one usage row'
stored_model=$(cut -f1 "$usage_file")
expected_model=$(jq -r '.model | @base64' "$work/response.original")
[[ "$stored_model" == "b64:$expected_model" ]] || fail 'usage storage preserves the raw provider model losslessly'
printf '%s\n' "${stored_model#b64:}" | jq -Rj '@base64d' | cmp - <(jq -j '.model' "$work/response.original") || fail 'encoded usage model decodes to original provider bytes'
__lmline_usage_summary
[[ "$usage_model" == 'provider model 900 800 700 injected' ]] || fail 'provider model label is terminal-safe and single-line'
[[ "$usage_prompt/$usage_completion/$usage_total" == 1/2/3 ]] || fail 'provider model delimiters do not corrupt usage counters'
cmp -s "$work/response.original" "$work/response.json" || fail 'usage recording leaves provider response unchanged'
cmp -s "$work/response.json" "$LMLINE_TRACE_DIR/fixture.response" || fail 'provider trace retains the unmodified response'
jq -e --arg model "$raw_model" '.model == $model' "$LMLINE_TRACE_DIR/fixture.response" >/dev/null || fail 'provider trace retains the original model field'

__lmline_emit_status 2>"$work/status"
[[ $(cat "$work/status") == 'lmline-status: m=provider model 900 800 700 injected; tok=1/2/3; t=5s' ]] || fail 'status emits sanitized model and accurate counts'
__lmline_emit_meta 2>"$work/meta"
[[ $(cat "$work/meta") == 'lmline-meta: model=provider model 900 800 700 injected tokens=3 prompt=1 completion=2 tools=none time=5s' ]] || fail 'metadata emits sanitized model and accurate counts'

# Missing or broken renderers must not fall back to raw provider-controlled text.
unset -f __lmline_display_answer
__lmline_usage_summary
[[ "$usage_model" == unknown-model ]] || fail 'missing model renderer fails closed'
__lmline_display_answer() { cat; return 43; }
__lmline_usage_summary
[[ "$usage_model" == unknown-model ]] || fail 'failed model renderer fails closed'
ok 'terminal-safe provider model metadata and usage framing'
