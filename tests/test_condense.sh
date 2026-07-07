#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
__lmline_init_dirs "$repo_dir/lmline"
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"

patterns=$(__lmline_condense_patterns_file)
[[ "$patterns" == */condense_priority_patterns.txt ]] || fail "patterns file resolution"

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
cond_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-condense.XXXXXX")
trap 'rm -rf "$cond_tmp"' EXIT
printf 'small file\n' >"$cond_tmp/small"
__lmline_condense_file "$cond_tmp/small" 1000
[[ "$(cat "$cond_tmp/small")" == "small file" ]] || fail "small file untouched"
printf '%s\n' "$long_in" >"$cond_tmp/large"
__lmline_condense_file "$cond_tmp/large" 2000
grep -q '\.\.\.\[omitted' "$cond_tmp/large" || fail "large file condensed in place"

ok "output condensation"
