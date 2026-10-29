#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: actual Unicode C1 controls never become selectable commands; ordinary
# UTF-8 continuation bytes and the user's existing input remain untouched.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-candidate-controls.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
safe='echo café-日本-一'
export LMLINE_TEST_EXEC_MARKER="$tmp/executed"
bad=$'echo \302\235title\302\234 $(touch "$LMLINE_TEST_EXEC_MARKER")'
printf '%s\n' "$bad" >"$tmp/bad"
printf '%s\n' "$safe" >"$tmp/safe"
# Both endpoints and every interior codepoint, plus the existing C0/DEL guard.
cat >"$tmp/policy-test" <<'POLICY'
set -euo pipefail
source "$1/lmline/context.bash"
source "$1/lmline/actions.bash"
source "$1/lmline/policy.bash"
for byte in {128..159}; do
  printf -v octal '%03o' "$byte"
  printf -v control '\302%b' "\\$octal"
  [[ $(__lmline_candidate_rejection_reason "echo $control") == control-character ]]
done
for control in $'\001' $'\033' $'\177'; do
  [[ $(__lmline_candidate_rejection_reason "echo $control") == control-character ]]
done
safe=$(cat "$2/safe")
[[ $(__lmline_candidate_rejection_reason "$safe") == ok ]]
# Reject before truncation, including a C1 after the byte limit.
for candidate in "$(cat "$2/bad")" $'echo abcdefghijklmnopqrstuvwxyz\302\235'; do
  [[ -z $(printf '%s\n' "$candidate" | LMLINE_MAX_CANDIDATE_BYTES=16 __lmline_valid_candidates) ]]
done
[[ $(cat "$2/bad" "$2/safe" | __lmline_valid_candidates) == "$safe" ]]
# Copilot inline edits use the same validator inside the isolated child.
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  output=$(printf 'bad\t%s\nsafe\t%s\n' "$(cat "$2/bad")" "$safe" |
    __LMLINE_VALIDATION_ISOLATED=1 __lmline_copilot_filter_candidates "$shell" rewrite)
  [[ ${output##*$'\t'} == "$safe" && "$output" != *title* ]]
done
POLICY
locales=(C)
utf8_locale=$(locale -a | grep -iE '^(C\.(utf-?8)|en_US\.utf-?8)$' | head -1 || true)
[[ -z "$utf8_locale" ]] || locales+=("$utf8_locale")
for locale in "${locales[@]}"; do
  LC_ALL=$locale bash "$tmp/policy-test" "$repo_dir" "$tmp" || fail "C1 policy ($locale)"
done
ok 'C1 policy rejects all codepoints, preserves safe UTF-8, and filters Copilot edits'

# A custom engine bypasses policy, exercising the widgets' independent protocol
# admission defense. The same admission path handles synchronous and file loads.
cat >"$tmp/engine" <<'ENGINE'
#!/usr/bin/env bash
cat "$LMLINE_TEST_PROTOCOL_FILE"
ENGINE
chmod +x "$tmp/engine"
cat >"$tmp/selector" <<'SELECTOR'
#!/usr/bin/env bash
tee "$LMLINE_TEST_MENU_FILE" | head -1
SELECTOR
chmod +x "$tmp/selector"
cat >"$tmp/widget-test" <<'WIDGET'
set -e
repo=$1
work=$2
shell=$3
if [[ "$shell" == bash ]]; then
  source "$repo/lmline/init.bash"
  generate() { __lmline_generate_widget; }
  count() { printf '%s' "${#__LMLINE_CANDIDATES[@]}"; }
  dump() { printf '%s\n' "${__LMLINE_CANDIDATES[@]}"; }
  load() { __lmline_load_candidates_from_file "$LMLINE_TEST_PROTOCOL_FILE"; }
  buffer() { printf '%s' "$READLINE_LINE"; }
  cursor() { printf '%s' "$READLINE_POINT"; }
  initial() { READLINE_LINE=$original; READLINE_POINT=3; }
else
  source "$repo/lmline/init.zsh"
  generate() { lmline-zsh-generate-widget || (( ${#__LMLINE_ZSH_CANDIDATES[@]} == 0 )); }
  count() { printf '%s' "${#__LMLINE_ZSH_CANDIDATES[@]}"; }
  dump() { printf '%s\n' "${__LMLINE_ZSH_CANDIDATES[@]}"; }
  load() { __lmline_zsh_load_candidates_from_file "$LMLINE_TEST_PROTOCOL_FILE"; }
  buffer() { printf '%s' "$BUFFER"; }
  cursor() { printf '%s' "$CURSOR"; }
  initial() { BUFFER=$original; CURSOR=3; }
fi
safe=$(cat "$work/safe")
bad=$(cat "$work/bad")
# This is user input, not a provider suggestion: never strip or rewrite it.
original=$(printf '# user \302\235 café')
locale_before=$LC_ALL
options_before=$(set +o)
for batch in mixed rejected; do
  printf 'lmline-candidate: low\t-\t-\t%s\n' "$bad" >"$LMLINE_TEST_PROTOCOL_FILE"
  # Separate ST, the C1 endpoints, ESC and DEL must also be rejected.
  for control in $'\302\234' $'\302\200' $'\302\237' $'\033' $'\177'; do
    printf 'lmline-candidate: low\t-\t-\techo %s\n' "$control" >>"$LMLINE_TEST_PROTOCOL_FILE"
  done
  if [[ "$batch" == mixed ]]; then
    printf 'lmline-candidate: low\t-\t-\t%s\n' "$safe" >>"$LMLINE_TEST_PROTOCOL_FILE"
    printf 'lmline-candidate: low\t-\t-\techo safe-two\n' >>"$LMLINE_TEST_PROTOCOL_FILE"
    expected=2
  else
    expected=0
  fi
  initial
  generate
  [[ $(count) == "$expected" ]]
  if [[ "$batch" == mixed ]]; then
    [[ $(buffer) == "$safe" && $(dump) == "$safe"$'\n'"echo safe-two" ]]
    if [[ "$shell" == bash ]]; then
      [[ $(cat "$LMLINE_TEST_MENU_FILE") == "$safe"$'\n'"echo safe-two" ]]
    fi
  else
    [[ $(buffer) == "$original" && $(cursor) == 3 ]]
  fi
  initial
  load
  [[ $(count) == "$expected" && $(buffer) == "$original" && $(cursor) == 3 ]]
  [[ "$LC_ALL" == "$locale_before" && $(set +o) == "$options_before" ]]
done
# Neither suggestion recording nor shell history may contain rejected text.
if [[ "$shell" == bash ]]; then history; else fc -l 1; fi >"$work/$shell.history" 2>/dev/null || true
WIDGET
for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null; then
    printf 'skip - C1 %s widgets (shell unavailable)\n' "$shell"
    continue
  fi
  shell_flags=(-f -e -i)
  [[ "$shell" != bash ]] || shell_flags=(--norc -e -i)
  for locale in "${locales[@]}"; do
    LC_ALL=$locale LMLINE_HISTORY_DIR="$tmp/history-$shell" LMLINE_CONFIG_DIR="$tmp/config-$shell" LMLINE_ENGINE="$tmp/engine" \
      LMLINE_ASYNC=0 LMLINE_SPINNER=0 LMLINE_SELECTOR="$tmp/selector" \
      LMLINE_TEST_PROTOCOL_FILE="$tmp/protocol-$shell" LMLINE_TEST_MENU_FILE="$tmp/menu-$shell" \
      "$shell" "${shell_flags[@]}" -c 'source "$1" "$2" "$3" "$4"' _ \
        "$tmp/widget-test" "$repo_dir" "$tmp" "$shell" \
        >"$tmp/$shell.out" 2>"$tmp/$shell.err" || fail "C1 $shell widgets ($locale)"
    ! LC_ALL=C grep -q $'\302[\200-\237]' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell C1 display leak"
  done
  [[ -s "$tmp/history-$shell/suggestions.log" ]] || fail "$shell missing suggestion log"
  ! grep -RFq 'title' "$tmp/history-$shell" "$tmp/$shell.history" 2>/dev/null || fail "$shell history leak"
  ! grep -Fq 'title' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell display leak"
done
ok 'C1 widget admission preserves buffers and safe UTF-8 without execution or history/display leaks'

# Exercise actual provider parsing through the engine, including rejection
# before byte truncation and raw trace retention. Never contact a network.
mkdir "$tmp/bin"
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
while (($#)); do
  case "$1" in
    -o) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
cp "$LMLINE_TEST_RESPONSE" "$output"
printf '200\tapplication/json'
CURL
chmod +x "$tmp/bin/curl"
printf '# suggest a command\n' >"$tmp/line"
printf '## available_tools\n' >"$tmp/context"
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  for batch in mixed rejected; do
    text=$bad$'\n'"echo abcdefghijklmnopqrstuvwxyz"$'\302\235'
    [[ "$batch" != mixed ]] || text+=$'\n'"$safe"
    jq -n --arg text "$text" '{choices:[{message:{role:"assistant",content:$text},finish_reason:"stop"}]}' >"$tmp/response.json"
    if PATH="$tmp/bin:$PATH" LMLINE_TEST_RESPONSE="$tmp/response.json" \
      LMLINE_CONFIG_DIR="$tmp/config-engine" LMLINE_BASE_URL=https://api.test.invalid/v1 \
      LMLINE_MODEL=test-model LMLINE_TOOL_MODE=none LMLINE_MAX_CANDIDATE_BYTES=24 \
      LMLINE_TRACE_DIR="$tmp/trace" \
      "$repo_dir/lmline/engine" --mode generate --shell "$shell" --cwd "$repo_dir" \
        --point 0 --line-file "$tmp/line" --context-file "$tmp/context" --n 3 \
        >"$tmp/engine.out" 2>"$tmp/engine.err"; then
      [[ "$batch" == mixed ]] || fail 'all C1 candidates accepted by engine'
      [[ $(candidates_of <"$tmp/engine.out") == "$safe" ]] || fail 'engine changed safe UTF-8'
    else
      [[ "$batch" == rejected ]] || fail 'engine rejected mixed safe UTF-8'
      [[ -z $(candidates_of <"$tmp/engine.out") ]] || fail 'engine leaked rejected candidate'
    fi
    ! LC_ALL=C grep -q $'\302[\200-\237]' "$tmp/engine.out" "$tmp/engine.err" || fail 'engine C1 display leak'
    grep -RFq "$bad" "$tmp/trace" || fail 'raw rejected trace was changed'
  done
done
[[ ! -e "$LMLINE_TEST_EXEC_MARKER" ]] || fail 'candidate executed'
ok 'C1 engine rejection precedes truncation, retains raw traces, and emits only safe candidates'
