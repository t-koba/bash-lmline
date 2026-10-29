#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: provider-controlled tool names reach the terminal through progress or
# status labels. Assertions are boolean-only; never print raw control bytes.
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"
work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-progress-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Keep ordinary text and strip terminal-active C0/C1, CSI, and OSC sequences.
for sequence in $'\e]52;c;payload\a' $'\e[31m' $'\302\235payload\302\234' \
  $'\302\23331m' $'\001\177\302\205'; do
  raw_name="prefix${sequence}suffix"
  display_name=$(__lmline_tool_short_name "$raw_name")
  [[ "$display_name" == prefixsuffix ]] || fail 'unknown tool label preserves text and strips controls'

  LMLINE_PROGRESS=1 __lmline_progress "tool ${display_name} (openai, round 1/3)" 2>"$work/progress"
  [[ $(cat "$work/progress") == 'lmline-progress: tool prefixsuffix (openai, round 1/3)' ]] || fail 'progress protocol contains only safe display label'

  tools_file=$work/tools
  : >"$tools_file"
  __lmline_record_tool "$raw_name"
  [[ $(__lmline_tools_summary) == prefixsuffix ]] || fail 'status tool summary contains only safe display label'
  __lmline_usage_summary() {
    usage_model=fixture
    usage_prompt=0
    usage_completion=0
    usage_total=0
  }
  __lmline_elapsed_seconds() { printf '1'; }
  __lmline_emit_status 2>"$work/status"
  [[ $(cat "$work/status") == 'lmline-status: m=fixture; tok=?/?/?; tools=prefixsuffix; t=1s' ]] || fail 'status protocol contains only safe display label'
  [[ $(__lmline_tool_output "$raw_name" '{}') == "tool disabled by configuration: $raw_name" ]] || fail 'raw tool name remains available to protocol handling'
done

# Newlines are ordinary text for the answer renderer; flatten them for the
# single-line progress/status protocols instead of permitting extra records.
raw_name=$'before\nlmline-progress: injected'
display_name=$(__lmline_tool_short_name "$raw_name")
[[ "$display_name" == 'before lmline-progress: injected' ]] || fail 'tool label is flattened to one line'

# Full provider response traces retain the raw name independently of display.
LMLINE_TRACE_DIR=$work/trace
trace_id=fixture
mkdir -p "$LMLINE_TRACE_DIR"
raw_name=$'provider_\302\23552;c;payload\302\234'
jq -cn --arg name "$raw_name" '{function:{name:$name}}' >"$work/response.json"
__lmline_trace_file tool-call "$work/response.json"
jq -e --arg name "$raw_name" '.function.name == $name' "$LMLINE_TRACE_DIR/fixture.tool-call" >/dev/null || fail 'raw tool name remains intact in trace'

# Sanitizer failure is closed with a static label, never raw provider text.
unset -f __lmline_display_answer
display_name=$(__lmline_tool_short_name "$raw_name")
[[ "$display_name" == unknown-tool ]] || fail 'missing display renderer fails closed'
__lmline_display_answer() { cat; return 43; }
display_name=$(__lmline_tool_short_name "$raw_name")
[[ "$display_name" == unknown-tool ]] || fail 'failed display renderer fails closed'
[[ $(__lmline_tool_short_name command_exists) == command-exists ]] || fail 'known tool labels remain unchanged'
ok 'terminal-safe provider tool progress and status labels'
