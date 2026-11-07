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

# Append only between completed polls, not on wall-clock deadlines. The actual
# spinner runs in each shell; sleep/kill delimit its ticks and a real child
# supplies the wait status. Check every frame, including awk fallback after NUL.
cat >"$work/spinner-test" <<'SHELL'
repo=$1
work=$2
shell=$3
if [[ $shell == bash ]]; then
  source "$repo/lmline/init.bash"
  spinner() { __lmline_wait_with_spinner "$@"; }
  __lmline_spinner_enabled() { [[ $enabled == 1 ]]; }
  __lmline_hint() { check_hint "$2"; }
else
  source "$repo/lmline/init.zsh"
  spinner() { __lmline_zsh_wait_with_spinner "$@"; }
  __lmline_zsh_spinner_enabled() { [[ $enabled == 1 ]]; }
  __lmline_zsh_hint() { check_hint "$1"; }
fi
LMLINE_PS0='test: '
LMLINE_SPINNER_INTERVAL=0.2
awk() { printf '.\n' >>"$work/awk-calls"; command awk "$@"; }
kill() { (( polls < limit )); }
closed() { ! ( : <&"$1" ) 2>/dev/null; }
check_hint() {
  polls=$((polls + 1))
  case $polls in
    1|2|5) expected=fallback ;;
    3) expected=par ;;
    4) expected=partial ;;
    6|7) expected=$'carriage\r' ;;
    8) expected=later ;;
    *) exit 80 ;;
  esac
  if [[ $mode == missing ]]; then expected=fallback; fi
  case $(( (polls - 1) % 3 )) in
    0) frame='.  ' ;; 1) frame='.. ' ;; 2) frame='...' ;;
  esac
  [[ $1 == "test: ${expected}${frame} $(( (polls - 1) / 5 ))s" ]] || exit 81
  if [[ $mode != missing ]]; then
    if (( polls == 1 )); then
      saved_read=$progress_fd
      saved_guard=$guard_fd
      [[ -n $saved_read && -n $saved_guard && $saved_read != "$saved_guard" ]] || exit 82
    fi
    if (( polls >= 7 )); then
      closed "$saved_read" && closed "$saved_guard" || exit 83
    fi
  fi
}
sleep() {
  [[ $1 == 0.2 ]] || exit 84
  [[ $mode != missing ]] || return 0
  case $polls in
    1) printf 'lmline-pro' ;;
    2) printf 'gress: par' ;;
    3) printf 'tial\nnoise' ;;
    4) printf ' continuation\nlmline-progress: \n' ;;
    5) printf 'lmline-progress: carriage\r' ;;
    6) printf '\n\0lmline-progress: fake\n' ;;
    7) printf 'lmline-progress: later\n' ;;
  esac >>"$log"
}
for mode in normal binary missing disabled; do
  polls=0 enabled=1 limit=8
  [[ $mode != normal ]] || limit=6
  log=$work/$mode.log
  : >"$log"
  : >"$work/awk-calls"
  [[ $mode != missing ]] || rm "$log"
  [[ $mode != disabled ]] || enabled=0
  ( exit 37 ) & child=$!
  result=0
  spinner "$child" fallback "$log" || result=$?
  [[ $result == 37 ]] || exit 85
  case $mode in
    normal) calls=0; closed "$saved_read" && closed "$saved_guard" || exit 86 ;;
    binary) calls=2 ;;
    missing) calls=0 ;; # The helper does not invoke awk for a missing file.
    disabled) calls=0; [[ $polls == 0 ]] || exit 87 ;;
  esac
  [[ $(command awk 'END { print NR+0 }' "$work/awk-calls") == "$calls" ]] || exit 88
  [[ $mode == disabled || $polls == "$limit" ]] || exit 89
done
SHELL
for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null 2>&1; then
    printf 'skip - %s incremental progress spinner (shell unavailable)\n' "$shell"
    continue
  fi
  mkdir "$work/$shell"
  if [[ $shell == bash ]]; then
    LMLINE_CONFIG_DIR="$work/config-bash" LMLINE_BIND_KEYS=0 bash --norc -ic \
      'source "$1/spinner-test" "$2" "$1/bash" bash' _ "$work" "$repo_dir" \
      >"$work/bash.out" 2>"$work/bash.err" || fail 'Bash incremental progress spinner'
  else
    LMLINE_CONFIG_DIR="$work/config-zsh" LMLINE_BIND_KEYS=0 zsh -fic \
      'source "$1/spinner-test" "$2" "$1/zsh" zsh' _ "$work" "$repo_dir" \
      >"$work/zsh.out" 2>"$work/zsh.err" || fail 'Zsh incremental progress spinner'
  fi
  ok "$shell incremental progress spinner labels, fallback, frames, status and descriptor lifetime"
done
