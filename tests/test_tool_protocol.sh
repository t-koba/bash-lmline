#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the text tool protocol has one grammar, so the candidate check and the
# parser answer the same way about the shape of a text.

# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
__lmline_init_dirs "$repo_dir/lmline"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"

export LMLINE_TRACE_DIR=""
export LMLINE_TOOL_FILES=1 LMLINE_TOOL_COMMAND_EXISTS=1

proto_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-tool-protocol.XXXXXX")
trap 'rm -rf "$proto_tmp"' EXIT

# The candidate check and the parser must answer the same way about a text:
# a text that names a local tool is a tool request, and it is parsed as one.
# The second field is the expected answer.
while IFS='|' read -r text expected; do
  [[ -n "$text" ]] || continue
  if __lmline_contains_tool_request "$text"; then contains=yes; else contains=no; fi
  [[ "$contains" == "$expected" ]] || fail "the candidate check answers $contains for [$text]"
  status=0
  __lmline_text_tool_requests_from_text "$text" "$proto_tmp/calls" 2>/dev/null || status=$?
  if [[ "$expected" == yes ]]; then
    [[ "$status" == 0 ]] || fail "the parser refuses [$text]"
    [[ -s "$proto_tmp/calls" ]] || fail "the parser produces no call for [$text]"
  else
    [[ "$status" != 0 ]] || fail "the parser accepts [$text]"
    [[ ! -s "$proto_tmp/calls" ]] || fail "the parser produces a call for [$text]"
  fi
done <<'CASES'
TOOL files query=x|yes
command_exists awk|yes
tool command_exists awk|yes
ls; TOOL files query=x|yes
ls; tool files query=x|yes
echo hi; TOOL command_exists commands=awk|yes
TOOL bogus x|no
ls; TOOL bogus x|no
echo hi|no
ls;TOOL files query=x|no
echo "see; TOOL files query=x"|no
CASES
ok "the candidate check and the parser answer the same way"

# The appended request names the tool it asks for and keeps its argument.
__lmline_text_tool_requests_from_text "ls; TOOL files query=x" "$proto_tmp/calls"
jq -e 'select(.function.name == "files") | .function.arguments | fromjson | .query == "x"' \
  "$proto_tmp/calls" >/dev/null || fail "the appended request names no tool or loses its argument"
ok "the appended request is parsed"

# A request that names no known tool is traced and produces no call.
trace_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-tool-trace.XXXXXX")
trap 'rm -rf "$proto_tmp" "$trace_tmp"' EXIT
status=0
LMLINE_TRACE_DIR="$trace_tmp" __lmline_text_tool_requests_from_text "TOOL bogus x" "$proto_tmp/calls" 2>/dev/null || status=$?
[[ "$status" != 0 ]] || fail "an unknown tool name is accepted"
grep -q 'unknown tool name: bogus' "$trace_tmp"/*.text-tool-parse.log 2>/dev/null \
  || fail "an unknown tool name is not traced"
ok "an unknown tool name is refused and traced"

# A request for a tool that is off is not used, and it does not stop the
# other requests of the text.
export LMLINE_TOOL_FILES=0
__lmline_text_tool_requests_from_text "TOOL files query=x
TOOL command_exists commands=awk" "$proto_tmp/calls"
jq -e 'select(.function.name == "command_exists")' "$proto_tmp/calls" >/dev/null \
  || fail "a disabled tool stops the other requests"
! jq -e 'select(.function.name == "files")' "$proto_tmp/calls" >/dev/null || fail "a disabled tool is used"
export LMLINE_TOOL_FILES=1
ok "a disabled tool is skipped, not obeyed"

ok "tool protocol"
