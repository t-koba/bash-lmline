#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: output condensation preserves useful context and leaves short input untouched.

# Preserve the failing command location when an unexpected status triggers set -e.
set -E
trap 'status=$?; printf "not ok - test_condense.sh:%d (exit %d)\n" "$LINENO" "$status" >&2' ERR

# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
__lmline_init_dirs "$repo_dir/lmline"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"
# shellcheck source=lmline/actions.bash
source "$repo_dir/lmline/actions.bash"

patterns=$(__lmline_condense_patterns_file)
[[ "$patterns" == */condense_priority_patterns.txt ]] || fail "patterns file resolution"
cond_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-condense.XXXXXX")
trap 'rm -rf "$cond_tmp"' EXIT

# Short input passes through untouched.
short_out=$(printf 'line one\nline two\n' | __lmline_condense_text 1000 "$patterns")
[[ "$short_out" == $'line one\nline two' ]] || fail "short input unchanged"

# Long input keeps head and tail with an omission marker in between.
long_in=$(for i in $(seq 1 200); do printf 'filler line number %s with some padding text\n' "$i"; done)
long_out=$(printf '%s\n' "$long_in" | __lmline_condense_text 2000 "$patterns")
grep -q 'filler line number 1 ' <<<"$long_out" || fail "head preserved"
grep -q 'filler line number 200 ' <<<"$long_out" || fail "tail preserved"
grep -q '\.\.\.\[omitted [0-9]* lines' <<<"$long_out" || fail "omission marker"
out_bytes=$(LC_ALL=C printf '%s' "$long_out" | wc -c | tr -d ' ')
(( out_bytes <= 2200 )) || fail "budget respected (got $out_bytes bytes)"

# Priority lines (errors) in the omitted middle are rescued.
mixed_in=$(
  for i in $(seq 1 60); do printf 'boring output line %s aaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done
  printf 'Error: disk quota exceeded on /var/data\n'
  for i in $(seq 61 120); do printf 'boring output line %s aaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done
)
mixed_out=$(printf '%s\n' "$mixed_in" | __lmline_condense_text 1500 "$patterns")
grep -q 'Error: disk quota exceeded' <<<"$mixed_out" || fail "priority line rescued"

# An explicitly empty custom file replaces, rather than restores, built-ins.
empty_patterns_file=$cond_tmp/empty-patterns.txt
: >"$empty_patterns_file"
empty_out=$(printf '%s\n' "$mixed_in" | __lmline_condense_text 1500 "$empty_patterns_file")
grep -q '\.\.\.\[omitted' <<<"$empty_out" || fail "empty pattern file still condenses"
if grep -q 'Error: disk quota exceeded' <<<"$empty_out"; then
  fail "empty custom patterns do not rescue omitted ERROR line"
fi

# Explicit missing paths fail through the resolver and retain its diagnostic.
missing_patterns_file=$cond_tmp/missing-patterns.txt
if resolver_error=$(LMLINE_CONDENSE_PATTERNS_FILE="$missing_patterns_file" __lmline_condense_patterns_file 2>&1); then
  fail "missing explicit pattern file rejected"
fi
grep -Fq "lmline: condense_priority_patterns file is not readable: $missing_patterns_file" <<<"$resolver_error" ||
  fail "missing pattern resolver diagnostic"

# Consecutive duplicate lines fold into one annotated line.
dup_in=$(
  printf 'start\n'
  for _ in $(seq 1 50); do printf 'same repeated warning\n'; done
  printf 'end\n'
)
dup_out=$(printf '%s\n' "$dup_in" | __lmline_condense_text 200 "$patterns")
[[ $(grep -c 'same repeated warning' <<<"$dup_out") == 1 ]] || fail "duplicates folded"
grep -q 'same repeated warning (repeated 50x)' <<<"$dup_out" || fail "fold annotation"
grep -q '^start$' <<<"$dup_out" || fail "fold keeps head"
grep -q '^end$' <<<"$dup_out" || fail "fold keeps tail"

# Long lines are cut at UTF-8 boundaries, never mid-character.
utf8_line=$(printf 'あ%.0s' $(seq 1 1000))
utf8_out=$(printf '%s\n' "$utf8_line" | LMLINE_CONDENSE_LINE_BYTES=100 __lmline_condense_text 5000 "$patterns")
printf '%s' "$utf8_out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "utf-8 boundary cut"
grep -q '<line truncated>' <<<"$utf8_out" || fail "line truncation marker"

# In-place file condensation only rewrites files over budget.
printf 'small file\n' >"$cond_tmp/small"
__lmline_condense_file "$cond_tmp/small" 1000
[[ "$(cat "$cond_tmp/small")" == "small file" ]] || fail "small file untouched"
printf '%s\n' "$long_in" >"$cond_tmp/large"
__lmline_condense_file "$cond_tmp/large" 2000
grep -q '\.\.\.\[omitted' "$cond_tmp/large" || fail "large file condensed in place"

# File condensation propagates resolver errors and leaves the source intact.
printf '%s\n' "$long_in" >"$cond_tmp/invalid-config-large"
cp "$cond_tmp/invalid-config-large" "$cond_tmp/invalid-config-expected"
if LMLINE_CONDENSE_PATTERNS_FILE="$missing_patterns_file" \
  __lmline_condense_file "$cond_tmp/invalid-config-large" 2000 2>"$cond_tmp/condense-error"; then
  fail "file condensation rejects missing explicit pattern file"
fi
cmp -s "$cond_tmp/invalid-config-large" "$cond_tmp/invalid-config-expected" ||
  fail "failed file condensation leaves source unchanged"
grep -Fq "lmline: condense_priority_patterns file is not readable: $missing_patterns_file" "$cond_tmp/condense-error" ||
  fail "file condensation preserves resolver diagnostic"

# The command_run tool must propagate both the failure and resolver message,
# rather than reporting a successful tool result with uncondensed output.
tool_args=$(jq -cn --arg command "printf '%1000s\\n' x" '{command:$command}')
# The condensation configuration is resolved before the output size is
# looked at, so a broken configuration fails the tool whatever the command
# produced.
if LMLINE_EXEC_BACKEND=local LMLINE_TOOL_COMMAND_RUN=1 \
  LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=100 \
  LMLINE_CONDENSE_PATTERNS_FILE="$missing_patterns_file" \
  __lmline_tool_output command_run "$tool_args" \
  >"$cond_tmp/tool-output" 2>"$cond_tmp/tool-error"; then
  fail "command_run propagates condensation failure"
fi
empty_args=$(jq -cn --arg command "true" '{command:$command}')
if LMLINE_EXEC_BACKEND=local LMLINE_TOOL_COMMAND_RUN=1 \
  LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT=100 \
  LMLINE_CONDENSE_PATTERNS_FILE="$missing_patterns_file" \
  __lmline_tool_output command_run "$empty_args" \
  >"$cond_tmp/tool-empty-output" 2>"$cond_tmp/tool-empty-error"; then
  fail "command_run propagates condensation failure without output"
fi
grep -Fq "lmline: condense_priority_patterns file is not readable: $missing_patterns_file" "$cond_tmp/tool-error" ||
  fail "command_run preserves resolver diagnostic"
if grep -q '^allowed=1$' "$cond_tmp/tool-output"; then
  fail "command_run does not report allowed success after condensation failure"
fi

# The integrated clipboard action must stop before calling the engine when
# configured condensation cannot resolve its patterns.
mkdir -p "$cond_tmp/clip"
cat >"$cond_tmp/clip/provider" <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 100); do printf 'clipboard filler line %s with padding text\n' "$i"; done
EOF
cat >"$cond_tmp/clip/engine" <<'EOF'
#!/usr/bin/env bash
: >"${LMLINE_TEST_ENGINE_MARKER:?}"
EOF
chmod +x "$cond_tmp/clip/provider" "$cond_tmp/clip/engine"
printf 'fake\t%s\n' "$cond_tmp/clip/provider" >"$cond_tmp/clip/providers.tsv"
if LMLINE_CLIPBOARD_PROVIDERS_FILE="$cond_tmp/clip/providers.tsv" \
  LMLINE_CLIPBOARD_PROVIDER=fake \
  LMLINE_CLIP_MAX_INPUT_BYTES=100 \
  LMLINE_CONDENSE_PATTERNS_FILE="$missing_patterns_file" \
  LMLINE_TEST_ENGINE_MARKER="$cond_tmp/clip/engine-called" \
  __lmline_print_clip "$cond_tmp/clip/engine" bash '' '' \
  >"$cond_tmp/clip/stdout" 2>"$cond_tmp/clip/stderr"; then
  fail "clipboard action rejects missing explicit pattern file"
fi
grep -Fq "lmline: condense_priority_patterns file is not readable: $missing_patterns_file" "$cond_tmp/clip/stderr" ||
  fail "clipboard action reports resolver diagnostic"
[[ ! -e "$cond_tmp/clip/engine-called" ]] || fail "clipboard action does not call engine with uncondensed text"

ok "output condensation"
