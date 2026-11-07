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

# Count JSON processes as well as checking exact rows: ordinary responses use
# one pass, while unsafe or multi-document inputs still run the legacy body.
jq() {
  printf '.\n' >>"$work/jq-calls"
  command jq "$@"
}
usage_case() {
  local label=$1 response=$2 expected=$3 calls=$4 diagnostics=${5:-no}
  printf '%s' "$response" >"$work/response.json"
  : >"$usage_file"
  : >"$work/jq-calls"
  __lmline_record_usage "$work/response.json" >"$work/usage.out" 2>"$work/usage.err" || fail "$label status"
  printf '%s' "$expected" >"$work/expected.tsv"
  cmp -s "$usage_file" "$work/expected.tsv" || fail "$label usage bytes"
  [[ ! -s "$work/usage.out" ]] || fail "$label stdout"
  [[ $(wc -l <"$work/jq-calls" | tr -d ' ') == "$calls" ]] || fail "$label jq count"
  if [[ "$diagnostics" == yes ]]; then
    [[ -s "$work/usage.err" ]] || fail "$label missing legacy diagnostic"
  elif [[ "$diagnostics" == no ]]; then
    [[ ! -s "$work/usage.err" ]] || fail "$label unexpected diagnostic"
  fi
}
usage_case 'missing usage' '{"model":"m"}' $'b64:bQ==\t0\t0\t0\n' 1
usage_case 'null usage' '{"usage":null}' $'-\t0\t0\t0\n' 1
usage_case 'alternate counters' '{"usage":{"prompt_tokens":false,"input_tokens":2,"output_tokens":3}}' $'-\t2\t3\t5\n' 1
usage_case 'digit strings' '{"usage":{"prompt_tokens":"01","completion_tokens":"2"}}' $'-\t01\t2\t012\n' 1
usage_case 'model NUL and newline' '{"model":"a\u0000b\n"}' $'b64:YQBiCg==\t0\t0\t0\n' 1
usage_case 'token newline' '{"usage":{"prompt_tokens":"1\n","total_tokens":3}}' $'-\t1\t0\t3\n' 6
# Bash versions differ in whether discarded NUL bytes produce a warning.
usage_case 'token NUL' '{"usage":{"prompt_tokens":"1\u0000","total_tokens":3}}' $'-\t1\t0\t3\n' 6 any
usage_case 'nested token' '{"usage":{"prompt_tokens":[1],"total_tokens":3}}' $'-\t[\n  1\n]\t0\t3\n' 6
usage_case 'boolean total' '{"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":true}}' $'-\t1\t2\ttrue\n' 6
usage_case 'scalar usage' '{"usage":1}' $'-\t\t\t\n' 6 yes
usage_case 'multiple valid documents' $'{}\n{}' $'-\n-\t0\n0\t0\n0\t0\n0\n' 6
usage_case 'false document' 'false' '' 2
usage_case 'null document' 'null' '' 2
usage_case 'malformed suffix' '{} trailing' '' 2
usage_case 'empty input' '' $'\t\t\t\n' 6
# A failed append must return its failure without retrying through fallback.
printf '{}' >"$work/response.json"
: >"$work/jq-calls"
if (usage_file=$work; __lmline_record_usage "$work/response.json") 2>"$work/usage.err"; then
  fail 'usage append failure status'
fi
[[ $(wc -l <"$work/jq-calls" | tr -d ' ') == 1 ]] || fail 'usage append failure retried'
unset -f jq
ok 'single-pass usage recording and conservative legacy fallback'

# Missing or broken renderers must not fall back to raw provider-controlled text.
unset -f __lmline_display_answer
__lmline_usage_summary
[[ "$usage_model" == unknown-model ]] || fail 'missing model renderer fails closed'
__lmline_display_answer() { cat; return 43; }
__lmline_usage_summary
[[ "$usage_model" == unknown-model ]] || fail 'failed model renderer fails closed'
ok 'terminal-safe provider model metadata and usage framing'
