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

# An invalid backend spelling must not silently become auto/local when the
# microsandbox command is unavailable.
if LMLINE_EXEC_BACKEND=microsandox \
  LMLINE_MICROSANDBOX_COMMAND="$list_tmp/missing-msb" \
  __lmline_select_exec_backend >"$list_tmp/invalid-backend-output" 2>/dev/null; then
  fail "an invalid execution backend selected a usable backend"
fi
invalid_backend_output=$(<"$list_tmp/invalid-backend-output")
[[ "$invalid_backend_output" == invalid ]] \
  || fail "an invalid execution backend returned no invalid-setting marker"
ok "an invalid execution backend fails closed"

# Exercise the command_run dispatch point with a harmless allowlisted command,
# replacing the actual capture function with a marker so no command can run.
backend_dispatch_marker="$list_tmp/backend-dispatch-marker"
backend_dispatch_output=$(
  export LMLINE_EXEC_BACKEND=microsandox
  export LMLINE_MICROSANDBOX_COMMAND="$list_tmp/missing-msb"
  __lmline_run_command_capture_with_backend() {
    printf 'called:%s\n' "$1" >>"$backend_dispatch_marker"
    return 0
  }
  __lmline_tool_command_run 'printf hi'
)
grep -q '^allowed=0$' <<<"$backend_dispatch_output" \
  || fail "the command tool allowed an invalid execution backend"
grep -q '^reason=invalid_execution_backend$' <<<"$backend_dispatch_output" \
  || fail "the command tool did not report an invalid execution backend"
[[ ! -e "$backend_dispatch_marker" ]] \
  || fail "the command tool dispatched an invalid execution backend"
ok "an invalid execution backend does not dispatch command_run"

# The risk ceiling is a restriction: a typo must not authorize medium-risk
# sandbox command_run. Use a capture recorder so no command executes.
export LMLINE_RISK_PATTERNS_FILE="$repo_dir/lmline/defaults/risk_patterns.tsv"
low_risk_reason=$(LMLINE_TOOL_COMMAND_RUN_MAX_RISK=low \
  __lmline_command_run_sandbox_rejection_reason 'printf probe >/dev/null')
[[ "$low_risk_reason" == risk_above_max:medium ]] \
  || fail "the valid low risk ceiling changed: $low_risk_reason"
medium_risk_reason=$(LMLINE_TOOL_COMMAND_RUN_MAX_RISK=medium \
  __lmline_command_run_sandbox_rejection_reason 'printf probe >/dev/null')
[[ "$medium_risk_reason" == ok ]] \
  || fail "the valid medium risk ceiling changed: $medium_risk_reason"
risk_dispatch_marker="$list_tmp/risk-dispatch-marker"
risk_dispatch_output=$(
  __lmline_run_command_capture_with_backend() {
    printf 'called:%s\n' "$1" >>"$risk_dispatch_marker"
    : >"$4"
    : >"$5"
    __LMLINE_EXEC_STATUS=0
  }
  LMLINE_EXEC_BACKEND=microsandbox \
    LMLINE_MICROSANDBOX_COMMAND=bash \
    LMLINE_TOOL_COMMAND_RUN_MAX_RISK=lo \
    __lmline_tool_command_run 'printf probe >/dev/null'
)
grep -q '^allowed=0$' <<<"$risk_dispatch_output" \
  || fail "an invalid risk ceiling allowed command_run: $risk_dispatch_output"
grep -q '^reason=invalid_max_risk$' <<<"$risk_dispatch_output" \
  || fail "an invalid risk ceiling had no diagnostic: $risk_dispatch_output"
[[ ! -e "$risk_dispatch_marker" ]] \
  || fail "an invalid risk ceiling dispatched a command"
ok "invalid command-run risk ceilings fail closed"

# Numeric command-run limits fail closed before dispatch: a malformed nonempty
# timeout or max-output must not call capture or execute the candidate, while
# valid limits and unset/empty defaults keep their behavior.
limits_marker="$list_tmp/limits-dispatch-marker"
limits_output=$(
  __lmline_run_command_capture_with_backend() {
    printf 'called:%s:%s\n' "$1" "$3" >>"$limits_marker"
    : >"$4"
    : >"$5"
    __LMLINE_EXEC_STATUS=0
  }
  LMLINE_EXEC_BACKEND=local \
    LMLINE_TOOL_COMMAND_RUN_TIMEOUT=1 \
    LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=64 \
    __lmline_tool_command_run 'printf hi'
)
grep -q '^allowed=1$' <<<"$limits_output" \
  || fail "valid numeric limits refused command_run: $limits_output"
grep -q '^stdout_truncated_to_bytes=64$' <<<"$limits_output" \
  || fail "valid max-output was not honored: $limits_output"
grep -q '^called:local:1$' "$limits_marker" \
  || fail "valid timeout was not passed to capture"
ok "valid command-run numeric limits still dispatch"
rm -f "$limits_marker"

invalid_timeout_output=$(
  __lmline_run_command_capture_with_backend() {
    printf 'called:%s\n' "$1" >>"$limits_marker"
    : >"$4"
    : >"$5"
    __LMLINE_EXEC_STATUS=0
  }
  LMLINE_EXEC_BACKEND=local \
    LMLINE_TOOL_COMMAND_RUN_TIMEOUT=1x \
    LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=64 \
    __lmline_tool_command_run 'printf hi'
)
grep -q '^allowed=0$' <<<"$invalid_timeout_output" \
  || fail "an invalid timeout allowed command_run: $invalid_timeout_output"
grep -q '^reason=invalid_timeout$' <<<"$invalid_timeout_output" \
  || fail "an invalid timeout had no diagnostic: $invalid_timeout_output"
[[ ! -e "$limits_marker" ]] \
  || fail "an invalid timeout dispatched a command"
ok "invalid command-run timeouts fail closed"
rm -f "$limits_marker"

invalid_max_output=$(
  __lmline_run_command_capture_with_backend() {
    printf 'called:%s\n' "$1" >>"$limits_marker"
    : >"$4"
    : >"$5"
    __LMLINE_EXEC_STATUS=0
  }
  LMLINE_EXEC_BACKEND=local \
    LMLINE_TOOL_COMMAND_RUN_TIMEOUT=1 \
    LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=64x \
    __lmline_tool_command_run 'printf hi'
)
grep -q '^allowed=0$' <<<"$invalid_max_output" \
  || fail "an invalid max-output allowed command_run: $invalid_max_output"
grep -q '^reason=invalid_max_output$' <<<"$invalid_max_output" \
  || fail "an invalid max-output had no diagnostic: $invalid_max_output"
[[ ! -e "$limits_marker" ]] \
  || fail "an invalid max-output dispatched a command"
ok "invalid command-run max-outputs fail closed"
rm -f "$limits_marker"

defaults_output=$(
  __lmline_run_command_capture_with_backend() {
    printf 'called:%s:%s\n' "$1" "$3" >>"$limits_marker"
    : >"$4"
    : >"$5"
    __LMLINE_EXEC_STATUS=0
  }
  LMLINE_EXEC_BACKEND=local \
    LMLINE_TOOL_COMMAND_RUN_TIMEOUT= \
    LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT= \
    __lmline_tool_command_run 'printf hi'
)
grep -q '^allowed=1$' <<<"$defaults_output" \
  || fail "empty numeric limits refused command_run: $defaults_output"
grep -q '^stdout_truncated_to_bytes=12000$' <<<"$defaults_output" \
  || fail "empty numeric limits lost their defaults: $defaults_output"
grep -q '^called:local:3$' "$limits_marker" \
  || fail "empty timeout lost its default"
ok "empty command-run numeric limits keep defaults"
rm -f "$limits_marker"

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
  "find . -fprintf out1 %p" "find . '-fprintf' out1 '%p'" \
  "find . -''fprint out1" "find . -f\"pri\"'nt' out1" 'find . -f\print out1'; do
  if [[ $(__lmline_local_literal_rejection_reason "$find_command") == ok ]]; then
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

# Isolated project and parent markers make path refusals observable through
# the real tool dispatch/capture path, without reading any machine data.
project="$list_tmp/project"
mkdir -p "$project/sub"
printf 'OUTSIDE_MARKER\n' >"$list_tmp/outside.txt"
printf 'INSIDE_MARKER\n' >"$project/inside.txt"
printf 'SPACE_MARKER\n' >"$project/inside space.txt"
printf 'PIPE_MARKER\n' >"$project/inside|pipe.txt"
printf 'INSIDE_MARKER\n' >"$project/inside\\space.txt"
printf 'INSIDE_MARKER\n' >"$project/inside\"quote.txt"
printf 'INSIDE_MARKER\n' >"$project/inside\\"
printf 'cat\nprintf\nfind\nwc\n' >"$list_file"
export LMLINE_LOCAL_COMMANDS_FILE="$list_file"
cd "$project" || fail "the isolated project is missing"

tool_command() {
  local args
  args=$(jq -cn --arg command "$1" '{command:$command}')
  LMLINE_EXEC_BACKEND=local LMLINE_TOOL_COMMAND_RUN=1 LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=100 \
    __lmline_tool_output command_run "$args" 2>/dev/null
}

assert_tool_refused() {
  local out
  out=$(tool_command "$1") || fail "tool dispatch failed"
  grep -q '^allowed=0$' <<<"$out" || fail "the tool allows an unsafe command: $1"
  grep -q "^reason=$2\$" <<<"$out" || fail "unexpected refusal for $1: $out"
  ! grep -q 'OUTSIDE_MARKER' <<<"$out" || fail "the tool read outside the project"
}

# Bash joins adjacent quote fragments before interpreting path operands.
# Include whole quotes, empty quotes, mixed quotes, and internal /../ parts.
for operand in "'$list_tmp/outside.txt'" "''$list_tmp/outside.txt" \
  "\"\"'$list_tmp/outside.txt'" "'${list_tmp%/*}/'\"${list_tmp##*/}\"/outside.txt" \
  "../outside.txt" "''../outside.txt" "'.'\".\"/outside.txt" \
  '\.\./outside.txt' "\\$list_tmp/outside.txt" \
  "sub/'..'/../outside.txt" "'sub/..'\"/..\"/outside.txt"; do
  assert_tool_refused "cat $operand" unsafe_path_or_expansion
done
ok "the tool refuses absolute and parent paths after literal quote removal"

# Assignment-style operands are checked after quote removal as well, while
# leading environment assignments and unallowlisted wrappers are not skipped.
for operand in "--file=''$list_tmp/outside.txt" "--file='..'/outside.txt" \
  "--file='..'" "--file=sub/'..'" "--file='~'/outside.txt" "x=a:~/outside.txt"; do
  assert_tool_refused "printf '%s' $operand" unsafe_path_or_expansion
done
assert_tool_refused "UNUSED=relative cat inside.txt" command_not_allowed
assert_tool_refused "command cat inside.txt" command_not_allowed
assert_tool_refused "t''rue" command_not_allowed
ok "the tool checks decoded command names and assignment-style operands"

# Expansion syntax is outside the local literal-word grammar. Validation
# must neither expand it nor execute its command text.
for command_line in 'cat inside*' 'cat # ignored' 'cat $(printf x > executed.txt)'; do
  assert_tool_refused "$command_line" unsupported_shell_syntax
done
[[ ! -e executed.txt ]] || fail "validation executed command substitution"
ok "the tool refuses expansions without evaluating them"

# Ordinary relative operands, spaces within quotes, empty arguments, mixed
# fragments, quoted command names, and pipelines keep their literal meaning.
for command_line in 'cat inside.txt' "cat 'inside.txt'" 'cat "inside space.txt"' \
  "c''at inside.txt" "cat in'side'\".txt\"" 'cat inside\ space.txt' \
  'cat "inside\space.txt"' "cat 'inside\\space.txt'" 'cat "inside\"quote.txt"' \
  "cat 'inside\\'"; do
  out=$(tool_command "$command_line") || fail "tool dispatch failed"
  grep -q '^allowed=1$' <<<"$out" || fail "a literal relative command was refused: $command_line: $out"
  grep -Eq '(INSIDE|SPACE)_MARKER' <<<"$out" || fail "the relative operand was not read"
done
out=$(tool_command "cat 'inside|pipe.txt' | cat") || fail "tool dispatch failed"
grep -q '^allowed=1$' <<<"$out" && grep -q PIPE_MARKER <<<"$out" || fail "a quoted pipe was misparsed"
out=$(tool_command "printf '%s:%s' '' --file='inside space.txt'") || fail "tool dispatch failed"
grep -q '^allowed=1$' <<<"$out" && grep -q ':--file=inside space.txt' <<<"$out" \
  || fail "empty or assignment-style relative operands were misparsed"
cd "$repo_dir" || fail "the repository directory is missing"
ok "the tool preserves literal relative words and pipelines"

ok "local commands"
