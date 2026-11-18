#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: concurrent widgets can corrupt the suggestion log by mixing records.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-suggestion-history.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# Exceed common shell stdio buffer sizes; one print call need not be one write.
printf -v padding '%8192s' ''
padding=${padding// /x}
cat >"$tmp/writer" <<'WRITER'
source "$1/lmline/init.$2"
writer=$3 padding=$4
await() {
  local attempt
  for ((attempt=0; attempt<400; ++attempt)); do
    [[ ! -e "$LMLINE_HISTORY_DIR/$1" ]] || return 0
    sleep 0.025
  done
  exit 1
}
# Force writer 2 to finish before writer 1 can resume after a standalone id
# write. With a full-record append, the final marker releases the other writers.
yield_after_id() {
  [[ $writer == 1 ]] || return 0
  : >"$LMLINE_HISTORY_DIR/first-id-or-done"
  await done-2
}
if [[ $2 == bash ]]; then
  printf() {
    builtin printf "$@" || return
    if [[ $# == 2 && $1 == 'id=%q\n' ]]; then yield_after_id; fi
  }
  record_suggestion=__lmline_record_suggestion
else
  print() {
    builtin print "$@" || return
    if [[ $# == 1 && $1 == id=* && $1 != *$'\n'* ]]; then yield_after_id; fi
  }
  record_suggestion=__lmline_zsh_record_suggestion
fi
if [[ $writer != 1 ]]; then
  await first-id-or-done
fi
"$record_suggestion" generate "original $writer-$padding" "candidate $writer-$padding"
: >"$LMLINE_HISTORY_DIR/done-$writer"
[[ $writer != 1 ]] || : >"$LMLINE_HISTORY_DIR/first-id-or-done"
WRITER

for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null; then
    printf 'skip - %s suggestion history (shell unavailable)\n' "$shell"
    continue
  fi
  flags=(-f -e -i)
  [[ $shell != bash ]] || flags=(--norc -e -i)
  history_dir="$tmp/history-$shell"
  mkdir -m 700 "$history_dir"
  pids=()
  for writer in 1 2 3; do
    LMLINE_CONFIG_DIR="$tmp/config-$shell" LMLINE_HISTORY_DIR="$history_dir" LMLINE_BIND_KEYS=0 \
      "$shell" "${flags[@]}" -c 'source "$@"' _ "$tmp/writer" "$repo_dir" "$shell" "$writer" "$padding" \
      >"$tmp/$shell-$writer.out" 2>&1 &
    pids+=("$!")
  done
  failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  if ((failed)); then
    cat "$tmp/""$shell"-*.out >&2
    fail "$shell suggestion writers did not finish"
  fi
  # Check the six fields in order and exactly one original/candidate pair per writer.
  awk -v pad="$padding" -v shell="$shell" '
    BEGIN {
      sep = (shell == "bash" ? "\\ " : " ")
      original = "original=original" sep
      candidate = "candidate=candidate" sep
    }
    NR % 6 == 1 { if ($0 !~ /^id=.+$/) exit 1 }
    NR % 6 == 2 { if ($0 !~ /^timestamp=.+$/) exit 1 }
    NR % 6 == 3 { if ($0 !~ /^cwd=.+$/) exit 1 }
    NR % 6 == 4 { if ($0 != "mode=generate") exit 1 }
    NR % 6 == 5 {
      pair = substr($0, length(original) + 1)
      if ($0 != original pair || pair !~ /^[123]-/ || substr(pair, 3) != pad || seen[pair]++) exit 1
    }
    NR % 6 == 0 { if ($0 != candidate pair) exit 1 }
    END { if (NR != 18) exit 1 }
  ' "$history_dir/suggestions.log" ||
    fail "$shell suggestion records interleaved or mismatched"
  ok "$shell suggestion history keeps concurrent records intact"
done
