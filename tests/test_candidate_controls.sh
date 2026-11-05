#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: Unicode C1/bidi controls never become selectable commands; ordinary
# UTF-8 continuation bytes and the user's existing input remain untouched.
tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-candidate-controls.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
safe='echo café-日本-一'
export LMLINE_TEST_EXEC_MARKER="$tmp/executed"
bidi_bad="echo 'left"$'\342\200\256'"right'"
bad=$'echo \302\235title\302\234 $(touch "$LMLINE_TEST_EXEC_MARKER")'
printf '%s\n' "$bad" >"$tmp/bad"
printf '%s\n' "$safe" >"$tmp/safe"
# Both endpoints and every interior codepoint, plus the existing C0/DEL guard.
cat >"$tmp/policy-test" <<'POLICY'
set -euo pipefail
source "$1/lmline/context.bash"
source "$1/lmline/actions.bash"
source "$1/lmline/policy.bash"
source "$1/lmline/chat.bash"
for byte in {128..159}; do
  printf -v octal '%03o' "$byte"
  printf -v control '\302%b' "\\$octal"
  [[ $(__lmline_candidate_rejection_reason "echo $control") == control-character ]]
done
# NUL cannot be represented by the line buffer: discard NUL-bearing raw
# candidate records before normalization or Bash reads can drop the byte.
nul_input() {
  printf '%b\n' '\0echo hidden-first' 'echo hidden-middle\0 text' 'echo hidden-end\0' 'echo nul-safe-companion'
  # A NUL-bearing final record without a newline must be dropped too.
  printf 'echo hidden-eof\0'
}
for filter in __lmline_filter_candidates __lmline_valid_candidates; do
  [[ $(nul_input | "$filter") == "echo nul-safe-companion" ]]
done
# Byte scanning must not decode/rewrite NUL-free UTF-8 or arbitrary bytes.
raw=$'echo café-日本-一\377\001'
[[ $(printf '%s' "$raw" | __lmline_filter_candidates) == "$raw" ]]
# Multiple clean records around NULs are preserved byte-exact; only tainted
# records are dropped, including those spanning NULs across newlines.
for filter in __lmline_filter_candidates __lmline_valid_candidates; do
  [[ $({ printf 'echo safe-before\n'; printf 'echo bad\0middle\n'; printf 'echo safe-middle\n'; printf 'a\0b\n'; printf 'echo safe-after\n'; } | "$filter") == $'echo safe-before\necho safe-middle\necho safe-after' ]]
  [[ $({ printf 'echo safe-one\n'; printf '\0\n'; printf 'echo safe-two\n'; printf 'a\0\0b\n'; printf 'echo safe-three\n'; } | "$filter") == $'echo safe-one\necho safe-two\necho safe-three' ]]
done
# Newline positions: NUL-then-newline drops the tainted record, newline-then-NUL
# drops only the NUL-bearing line, and unterminated finals behave the same.
[[ $(printf 'a\0\nb\n' | __lmline_filter_candidates) == "b" ]]
[[ $(printf 'a\n\0\nb\n' | __lmline_filter_candidates) == $'a\nb' ]]
[[ $(printf 'a\nb\0' | __lmline_filter_candidates) == "a" ]]
[[ -z $(printf 'a\0' | __lmline_filter_candidates) ]]
[[ -z $(printf '\0' | __lmline_filter_candidates) ]]
[[ -z $(printf '' | __lmline_filter_candidates) ]]
[[ -z $(printf '\n' | __lmline_filter_candidates) ]]
[[ -z $(printf '\n\n' | __lmline_filter_candidates) ]]
[[ $(printf 'a\n\nb\n' | __lmline_filter_candidates) == $'a\nb' ]]
# EOF without newline: clean finals gain a newline, NUL-bearing finals are dropped.
[[ $(printf 'echo safe-eof' | __lmline_filter_candidates) == "echo safe-eof" ]]
[[ -z $(printf 'echo bad-eof\0' | __lmline_filter_candidates) ]]
for filter in __lmline_filter_candidates __lmline_valid_candidates; do
  [[ $({ printf 'echo safe-first\n'; printf 'echo safe-eof'; } | "$filter") == $'echo safe-first\necho safe-eof' ]]
  [[ $({ printf 'echo safe-first\n'; printf 'echo bad-eof\0'; } | "$filter") == "echo safe-first" ]]
done
# Invalid/high bytes are preserved byte-exact when NUL-free and dropped only
# when tainted; safe companions prove no rewrite or leak.
high=$'echo \377\001\xff\xfe-xyz'
[[ $(printf '%s\n' "$high" | __lmline_filter_candidates) == "$high" ]]
[[ $(printf '%s' "$high" | __lmline_filter_candidates) == "$high" ]]
high_clean=$'echo \377\xff\xfe-xyz'
for filter in __lmline_filter_candidates __lmline_valid_candidates; do
  output=$({ printf '%s\n' "$high_clean"; printf 'bad\0\n'; printf 'echo safe-high\n'; printf '  - 2. `%s`  \n' "$high_clean"; } | "$filter" 2>"$2/locale-error")
  [[ $output == "$high_clean"$'\n'"echo safe-high"$'\n'"$high_clean" && ! -s $2/locale-error ]]
done
# Keep locale-aware UTF-8 whitespace normalization, not just byte preservation.
locale_before=$LC_ALL
space=' '
[[ $LC_ALL == C ]] || space=$'\343\200\200' # U+3000 is UTF-8 whitespace.
[[ $({ printf '%s```bash%s\n' "$space" "$space"; printf '%s- 2. `echo café-日本-一`%s\n' "$space" "$space"; } | __lmline_filter_candidates) == 'echo café-日本-一' ]]
[[ $LC_ALL == "$locale_before" ]]
# A spoofed caller read function cannot alter byte scanning: the clean
# $BASH -p child never imports it.
(
  read() { printf 'echo spoofed-via-read\n'; return 0; }
  [[ $(printf 'echo safe\n' | __lmline_filter_candidates) == "echo safe" ]]
  [[ $(nul_input | __lmline_filter_candidates) == "echo nul-safe-companion" ]]
)
# A scanner/child that produces output and then fails must admit nothing, even
# without caller pipefail. Stubs run only in these subshells.
for scanner in child normalizer; do
  (
    set +o pipefail
    if [[ $scanner == child ]]; then
      BASH=/bin/false
    else
      __lmline_normalize_candidate_line() { cat; return 1; }
    fi
    if output=$(printf 'echo scanner-partial\n' | __lmline_filter_candidates); then
      exit 1
    fi
    [[ -z $output ]]
  )
done
# A child that emits partial output and then fails still admits nothing.
(
  set +o pipefail
  printf '#!/usr/bin/env bash\nprintf "echo scanner-partial\\n"\nexit 1\n' >"$2/partial-bash"
  chmod +x "$2/partial-bash"
  BASH="$2/partial-bash"
  if output=$(printf 'echo scanner-partial\n' | __lmline_filter_candidates); then
    exit 1
  fi
  [[ -z $output ]]
)
for control in $'\001' $'\033' $'\177'; do
  [[ $(__lmline_candidate_rejection_reason "echo $control") == control-character ]]
done
# Exact Unicode Bidi_Control set, including controls inside quoted literals.
bidi=($'\330\234' $'\342\200\216' $'\342\200\217' \
  $'\342\200\252' $'\342\200\253' $'\342\200\254' $'\342\200\255' $'\342\200\256' \
  $'\342\201\246' $'\342\201\247' $'\342\201\250' $'\342\201\251')
rejected_file=$2/rejected
for control in "${bidi[@]}"; do
  [[ $(__lmline_candidate_rejection_reason "echo 'left${control}right'") == control-character ]]
  for candidate in "echo 'left${control}right'" "echo abcdefghijklmnopqrstuvwxyz$control"; do
    [[ -z $(printf '%s\n' "$candidate" | LMLINE_MAX_CANDIDATE_BYTES=16 __lmline_valid_candidates) ]]
    # The engine emitter must reject before truncation too, retaining raw data
    # only in its private rejection log, never as a rewritten command.
    [[ -z $(LMLINE_MAX_CANDIDATE_BYTES=16 __lmline_emit_candidates "$candidate") ]]
    [[ $(tail -1 "$rejected_file") == $'invalid:control-character\t'"$candidate" ]]
  done
done
safe=$(cat "$2/safe")
rtl='echo שלום-مرحبا'
[[ $(__lmline_candidate_rejection_reason "$rtl") == ok ]]
[[ $(printf '%s\n' "$rtl" | __lmline_valid_candidates) == "$rtl" ]]
[[ $(__lmline_candidate_rejection_reason "$safe") == ok ]]
# Reject before truncation, including a C1 after the byte limit.
for candidate in "$(cat "$2/bad")" $'echo abcdefghijklmnopqrstuvwxyz\302\235'; do
  [[ -z $(printf '%s\n' "$candidate" | LMLINE_MAX_CANDIDATE_BYTES=16 __lmline_valid_candidates) ]]
done
[[ $(cat "$2/bad" "$2/safe" | __lmline_valid_candidates) == "$safe" ]]
# Copilot inline edits use the same validator inside the isolated child.
for shell in bash zsh; do
  command -v "$shell" >/dev/null || continue
  output=$({
    printf 'bad\t%s\n' "$(cat "$2/bad")"
    for control in "${bidi[@]}"; do printf 'bad\techo %s\n' "$control"; done
    printf 'safe\t%s\n' "$safe"
  } |
    __LMLINE_VALIDATION_ISOLATED=1 __lmline_copilot_filter_candidates "$shell" rewrite)
  [[ ${output##*$'\t'} == "$safe" && "$output" != *title* ]]
done
POLICY
locales=(C)
utf8_locale=$(locale -a | grep -iE '^(C\.(utf-?8)|en_US\.utf-?8)$' | head -1 || true)
[[ -z "$utf8_locale" ]] || locales+=("$utf8_locale")
for locale in "${locales[@]}"; do
  LC_ALL=$locale bash "$tmp/policy-test" "$repo_dir" "$tmp" || fail "Unicode control policy ($locale)"
done
ok 'Unicode control policy rejects C1/bidi, preserves RTL text, and filters Copilot edits'

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
rtl='echo שלום-مرحبا'
bidi=($'\330\234' $'\342\200\216' $'\342\200\217' \
  $'\342\200\252' $'\342\200\253' $'\342\200\254' $'\342\200\255' $'\342\200\256' \
  $'\342\201\246' $'\342\201\247' $'\342\201\250' $'\342\201\251')
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
  # Exact Unicode Bidi_Control set, including controls inside quoted literals.
  for control in "${bidi[@]}"; do
    printf 'lmline-candidate: low\t-\t-\t%s\n' "echo 'left${control}right'" >>"$LMLINE_TEST_PROTOCOL_FILE"
  done
  if [[ "$batch" == mixed ]]; then
    printf 'lmline-candidate: low\t-\t-\t%s\n' "$safe" >>"$LMLINE_TEST_PROTOCOL_FILE"
    printf 'lmline-candidate: low\t-\t-\t%s\n' "$rtl" >>"$LMLINE_TEST_PROTOCOL_FILE"
    printf 'lmline-candidate: low\t-\t-\techo safe-two\n' >>"$LMLINE_TEST_PROTOCOL_FILE"
    expected=3
  else
    expected=0
  fi
  initial
  generate
  [[ $(count) == "$expected" ]]
  if [[ "$batch" == mixed ]]; then
    [[ $(buffer) == "$safe" && $(dump) == "$safe"$'\n'"$rtl"$'\n'"echo safe-two" ]]
    if [[ "$shell" == bash ]]; then
      [[ $(cat "$LMLINE_TEST_MENU_FILE") == "$safe"$'\n'"$rtl"$'\n'"echo safe-two" ]]
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
    printf 'skip - C1/bidi %s widgets (shell unavailable)\n' "$shell"
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
        >"$tmp/$shell.out" 2>"$tmp/$shell.err" || fail "C1/bidi $shell widgets ($locale)"
    ! LC_ALL=C grep -q $'\302[\200-\237]' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell C1 display leak"
    ! LC_ALL=C grep -q $'\330\234' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell bidi display leak"
    ! LC_ALL=C grep -q $'\342\200[\216-\217\252-\256]' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell bidi display leak"
    ! LC_ALL=C grep -q $'\342\201[\246-\251]' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell bidi display leak"
  done
  [[ -s "$tmp/history-$shell/suggestions.log" ]] || fail "$shell missing suggestion log"
  ! grep -RFq 'title' "$tmp/history-$shell" "$tmp/$shell.history" 2>/dev/null || fail "$shell history leak"
  ! grep -Fq 'title' "$tmp/$shell.out" "$tmp/$shell.err" || fail "$shell display leak"
done
ok 'C1/bidi widget admission preserves buffers and safe UTF-8 without execution or history/display leaks'

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
    text=$bad$'\n'"echo abcdefghijklmnopqrstuvwxyz"$'\302\235\n'"$bidi_bad"$'\n'"echo abcdefghijklmnopqrstuvwxyz"$'\342\200\256'
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
    grep -RFq "$bidi_bad" "$tmp/trace" || fail 'raw bidi trace was changed'
  done
done
# Provider JSON is checked before Bash extraction: unlike the record filter,
# this boundary rejects the whole response, including any safe companion.
for position in start middle end; do
  jq -n --arg position "$position" '
    "echo $(touch \"$LMLINE_TEST_EXEC_MARKER\")" as $cmd |
    (if $position == "start" then "\u0000" + $cmd
     elif $position == "middle" then "echo\u0000" + $cmd
     else $cmd + "\u0000" end) as $bad |
    {choices:[{message:{role:"assistant",content:($bad + "\necho nul-safe-companion")},finish_reason:"stop"}]}
  ' >"$tmp/response.json"
  if PATH="$tmp/bin:$PATH" LMLINE_TEST_RESPONSE="$tmp/response.json" \
    LMLINE_CONFIG_DIR="$tmp/config-engine" LMLINE_BASE_URL=https://api.test.invalid/v1 \
    LMLINE_MODEL=test-model LMLINE_TOOL_MODE=none \
    "$repo_dir/lmline/engine" --mode generate --shell bash --cwd "$repo_dir" \
      --point 0 --line-file "$tmp/line" --context-file "$tmp/context" --n 3 \
      >"$tmp/engine.out" 2>"$tmp/engine.err"; then
    fail "engine accepted NUL at $position"
  fi
  [[ -z $(candidates_of <"$tmp/engine.out") ]] || fail 'engine emitted altered NUL candidate'
  grep -q 'embedded NUL in response content' "$tmp/engine.err" || fail 'missing NUL diagnostic'
  ! grep -q 'touch\|nul-safe-companion' "$tmp/engine.out" "$tmp/engine.err" || fail 'NUL candidate display leak'
done
[[ ! -e "$LMLINE_TEST_EXEC_MARKER" ]] || fail 'candidate executed'
ok 'C1/bidi engine rejection precedes truncation, retains raw traces, and emits only safe candidates'
ok 'NUL at start/middle/end is rejected before engine extraction without execution or display leaks'
