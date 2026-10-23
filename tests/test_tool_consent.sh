#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: default-off tool opt-in fails closed across guard, request schema, and dispatch; stubs prevent real commands or project-file/git reads.

# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"

export LMLINE_TOOL_MODE=auto

set_tool_value() {
  local tool=$1 mode=$2 value=${3-}
  case "$tool" in
    git_status)
      if [[ "$mode" == unset ]]; then unset LMLINE_TOOL_GIT_STATUS
      else export LMLINE_TOOL_GIT_STATUS="$value"; fi ;;
    file_excerpt)
      if [[ "$mode" == unset ]]; then unset LMLINE_TOOL_FILE_EXCERPT
      else export LMLINE_TOOL_FILE_EXCERPT="$value"; fi ;;
    command_info)
      if [[ "$mode" == unset ]]; then unset LMLINE_TOOL_COMMAND_INFO
      else export LMLINE_TOOL_COMMAND_INFO="$value"; fi ;;
    command_run)
      if [[ "$mode" == unset ]]; then unset LMLINE_TOOL_COMMAND_RUN
      else export LMLINE_TOOL_COMMAND_RUN="$value"; fi ;;
  esac
}

clear_default_off() {
  unset LMLINE_TOOL_COMMAND_INFO LMLINE_TOOL_GIT_STATUS LMLINE_TOOL_FILE_EXCERPT LMLINE_TOOL_COMMAND_RUN 2>/dev/null || true
}

# --- shared guard: only exact `1` enables each default-off tool ---
disabled_values=(__UNSET__ "" "0" "false" "FALSE" "off" "OFF" "no" "NO" "flase" "disabled" "true" "yes" "2")
for tool in command_info git_status file_excerpt command_run; do
  for value in "${disabled_values[@]}"; do
    if [[ "$value" == __UNSET__ ]]; then
      set_tool_value "$tool" unset
    else
      set_tool_value "$tool" set "$value"
    fi
    if __lmline_tool_enabled "$tool"; then
      fail "default-off $tool enabled by $(printf '%q' "$value")"
    fi
  done
  set_tool_value "$tool" set "1"
  __lmline_tool_enabled "$tool" || fail "default-off $tool not enabled by exact 1"
  clear_default_off
done
ok "default-off guard requires exact 1"

# --- default-on tools keep existing behavior (sanity) ---
unset LMLINE_TOOL_FILES 2>/dev/null || true
__lmline_tool_enabled files || fail "default-on files disabled when unset"
export LMLINE_TOOL_FILES=0
if __lmline_tool_enabled files; then
  fail "default-on files enabled by 0"
fi
unset LMLINE_TOOL_FILES 2>/dev/null || true
ok "default-on files behavior preserved"

# --- advertisement: __lmline_available_tools omits default-off tools unless exact `1` ---
clear_default_off
tools_out=$(__lmline_available_tools)
! grep -q '^command_info commands=' <<<"$tools_out" || fail "advertised command_info when unset"
! grep -q '^git_status$' <<<"$tools_out" || fail "advertised git_status when unset"
! grep -q '^file_excerpt path=' <<<"$tools_out" || fail "advertised file_excerpt when unset"
! grep -q '^command_run command=' <<<"$tools_out" || fail "advertised command_run when unset"

export LMLINE_TOOL_COMMAND_INFO="" LMLINE_TOOL_GIT_STATUS="" LMLINE_TOOL_FILE_EXCERPT="" LMLINE_TOOL_COMMAND_RUN=""
tools_out=$(__lmline_available_tools)
! grep -q '^command_info commands=' <<<"$tools_out" || fail "advertised command_info when empty"
! grep -q '^git_status$' <<<"$tools_out" || fail "advertised git_status when empty"
! grep -q '^file_excerpt path=' <<<"$tools_out" || fail "advertised file_excerpt when empty"
! grep -q '^command_run command=' <<<"$tools_out" || fail "advertised command_run when empty"

export LMLINE_TOOL_COMMAND_INFO="flase" LMLINE_TOOL_GIT_STATUS="flase" LMLINE_TOOL_FILE_EXCERPT="flase" LMLINE_TOOL_COMMAND_RUN="flase"
tools_out=$(__lmline_available_tools)
! grep -q '^command_info commands=' <<<"$tools_out" || fail "advertised command_info when unrecognized"
! grep -q '^git_status$' <<<"$tools_out" || fail "advertised git_status when unrecognized"
! grep -q '^file_excerpt path=' <<<"$tools_out" || fail "advertised file_excerpt when unrecognized"
! grep -q '^command_run command=' <<<"$tools_out" || fail "advertised command_run when unrecognized"

export LMLINE_TOOL_COMMAND_INFO=1 LMLINE_TOOL_GIT_STATUS=1 LMLINE_TOOL_FILE_EXCERPT=1 LMLINE_TOOL_COMMAND_RUN=1
tools_out=$(__lmline_available_tools)
grep -q '^command_info commands=' <<<"$tools_out" || fail "missing command_info when exact 1"
grep -q '^git_status$' <<<"$tools_out" || fail "missing git_status when exact 1"
grep -q '^file_excerpt path=' <<<"$tools_out" || fail "missing file_excerpt when exact 1"
grep -q '^command_run command=' <<<"$tools_out" || fail "missing command_run when exact 1"
clear_default_off
ok "advertisement omits default-off tools unless exact 1"

# --- native payload: .tools[].function.name omits default-off tools unless exact `1` ---
payload_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-tool-consent.XXXXXX")
trap 'rm -rf "$payload_tmp"' EXIT
work_dir=$payload_tmp
export LMLINE_MODEL=test-model LMLINE_TEMPERATURE=0.2 LMLINE_TOOL_CHOICE=auto LMLINE_API_FORMAT=chat LMLINE_STORE=0
max_tokens=1200
printf '[{"role": "user", "content": "hi"}]' >"$payload_tmp/messages.json"

check_payload_tools() {
  local label=$1 expect=$2 names tool
  __lmline_write_chat_payload "$payload_tmp/messages.json" "$payload_tmp/payload.json" 1
  names=$(jq -r '(.tools // [])[].function.name' "$payload_tmp/payload.json")
  for tool in command_info git_status file_excerpt command_run; do
    if [[ "$expect" == present ]]; then
      grep -qx "$tool" <<<"$names" || fail "payload missing $tool ($label)"
    else
      ! grep -qx "$tool" <<<"$names" || fail "payload advertised $tool ($label)"
    fi
  done
}

clear_default_off
check_payload_tools "unset" absent
export LMLINE_TOOL_COMMAND_INFO="" LMLINE_TOOL_GIT_STATUS="" LMLINE_TOOL_FILE_EXCERPT="" LMLINE_TOOL_COMMAND_RUN=""
check_payload_tools "empty" absent
export LMLINE_TOOL_COMMAND_INFO="flase" LMLINE_TOOL_GIT_STATUS="flase" LMLINE_TOOL_FILE_EXCERPT="flase" LMLINE_TOOL_COMMAND_RUN="flase"
check_payload_tools "unrecognized" absent
export LMLINE_TOOL_COMMAND_INFO=1 LMLINE_TOOL_GIT_STATUS=1 LMLINE_TOOL_FILE_EXCERPT=1 LMLINE_TOOL_COMMAND_RUN=1
check_payload_tools "exact 1" present
clear_default_off
ok "payload tools omit default-off tools unless exact 1"

# --- dispatch: refused before any tool action (handlers stubbed, nothing executes or reads files) ---
__lmline_tool_command_info() { printf 'STUB-CALLED command_info\n'; }
__lmline_tool_git_status() { printf 'STUB-CALLED git_status\n'; }
__lmline_tool_file_excerpt() { printf 'STUB-CALLED file_excerpt\n'; }
__lmline_tool_command_run() { printf 'STUB-CALLED command_run\n'; }

check_dispatch_refused() {
  local tool=$1 args=$2 label=$3 out
  out=$(__lmline_tool_output "$tool" "$args" 2>/dev/null)
  grep -q "tool disabled by configuration: $tool" <<<"$out" || fail "dispatch did not refuse $tool ($label)"
  if grep -q 'STUB-CALLED' <<<"$out"; then
    fail "dispatch invoked $tool handler ($label)"
  fi
}

for tool in command_info git_status file_excerpt command_run; do
  case "$tool" in
    command_info) args='{"commands":"awk"}' ;;
    git_status) args='{}' ;;
    file_excerpt) args='{"path":"some/file.txt","query":"x"}' ;;
    command_run) args='{"command":"echo hi"}' ;;
  esac
  set_tool_value "$tool" unset
  check_dispatch_refused "$tool" "$args" "unset"
  set_tool_value "$tool" set ""
  check_dispatch_refused "$tool" "$args" "empty"
  set_tool_value "$tool" set "flase"
  check_dispatch_refused "$tool" "$args" "unrecognized"
  clear_default_off
done
ok "dispatch refuses disabled default-off tools without invoking handlers"

# Enabled dispatch reaches the handler (stub proves the allow path without running real actions).
export LMLINE_TOOL_COMMAND_INFO=1
out=$(__lmline_tool_output command_info '{"commands":"awk"}' 2>/dev/null)
grep -q 'STUB-CALLED command_info' <<<"$out" || fail "enabled command_info did not dispatch"
export LMLINE_TOOL_GIT_STATUS=1
out=$(__lmline_tool_output git_status '{}' 2>/dev/null)
grep -q 'STUB-CALLED git_status' <<<"$out" || fail "enabled git_status did not dispatch"
export LMLINE_TOOL_FILE_EXCERPT=1
out=$(__lmline_tool_output file_excerpt '{"path":"some/file.txt"}' 2>/dev/null)
grep -q 'STUB-CALLED file_excerpt' <<<"$out" || fail "enabled file_excerpt did not dispatch"
export LMLINE_TOOL_COMMAND_RUN=1
out=$(__lmline_tool_output command_run '{"command":"echo hi"}' 2>/dev/null)
grep -q 'STUB-CALLED command_run' <<<"$out" || fail "enabled command_run did not dispatch"
clear_default_off
ok "dispatch reaches handlers when exact 1"
