#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the local command allowlist answers from the content of its file, so
# an allowlisted command is never refused because of how the answer was read.

# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
__lmline_init_dirs "$repo_dir/lmline"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"

list_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-local-commands.XXXXXX")
trap 'rm -rf "$list_tmp"' EXIT

# The list is longer than a pipe buffer and the match comes first. A reader
# that stops at the match leaves the writer of the list with a closed pipe,
# and the writer's failure must not decide the answer.
list_file="$list_tmp/local_commands.txt"
printf 'printf\n' >"$list_file"
for i in $(seq 1 10000); do printf 'filler%s\n' "$i"; done >>"$list_file"
export LMLINE_LOCAL_COMMANDS_FILE="$list_file"

# The same question has one answer, however often it is asked.
for _ in 1 2 3 4 5; do
  __lmline_local_command_allowed printf || fail "an allowlisted command is refused"
done
ok "the allowlist answer is the content of the file"

# A command that the list does not name stays refused.
if __lmline_local_command_allowed not-in-the-list; then
  fail "a command outside the list is allowed"
fi
ok "a command outside the list stays refused"

# The tool path reports the same answer.
args=$(jq -cn --arg command "printf hi" '{command:$command}')
out=$(LMLINE_EXEC_BACKEND=local LMLINE_TOOL_COMMAND_RUN=1 LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=100 \
  __lmline_tool_output command_run "$args" 2>/dev/null || true)
grep -q '^allowed=1$' <<<"$out" || fail "the tool path refuses an allowlisted command: $(sed -n '1,3p' <<<"$out")"
ok "the tool path allows an allowlisted command"

# A command outside the list is refused by the tool path as well.
args=$(jq -cn --arg command "ls" '{command:$command}')
out=$(LMLINE_EXEC_BACKEND=local LMLINE_TOOL_COMMAND_RUN=1 LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=100 \
  __lmline_tool_output command_run "$args" 2>/dev/null || true)
grep -q '^allowed=0$' <<<"$out" || fail "the tool path allows a command outside the list: $(sed -n '1,3p' <<<"$out")"
grep -q '^reason=command_not_allowed$' <<<"$out" || fail "the tool path gives no reason for the refusal"
ok "the tool path refuses a command outside the list"

# A find action is refused in the spelling the shell passes to find, whether
# the action word is quoted or not: the shell removes the quotes before find
# sees the action.
find_list="$list_tmp/local_commands_with_find.txt"
printf 'find\nprintf\n' >"$find_list"
export LMLINE_LOCAL_COMMANDS_FILE="$find_list"
cd "$list_tmp" || fail "the temporary list directory is missing"
for find_command in "find . -exec true +" "find . '-exec' true +" \
  "find . -fprintf out1 %p" "find . '-fprintf' out1 '%p'"; do
  if __lmline_local_segment_allowed "$find_command"; then
    fail "the local path allows a find action: $find_command"
  fi
  args=$(jq -cn --arg command "$find_command" '{command:$command}')
  out=$(LMLINE_EXEC_BACKEND=local LMLINE_TOOL_COMMAND_RUN=1 LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=100 \
    __lmline_tool_output command_run "$args" 2>/dev/null || true)
  grep -q '^allowed=0$' <<<"$out" || fail "the tool path allows a find action: $find_command"
  grep -q '^reason=command_not_allowed$' <<<"$out" \
    || fail "the tool path gives no reason for the refusal: $find_command"
done
cd "$repo_dir" || fail "the repository directory is missing"
export LMLINE_LOCAL_COMMANDS_FILE="$list_file"
ok "the local path refuses a find action in either spelling"

ok "local commands"
