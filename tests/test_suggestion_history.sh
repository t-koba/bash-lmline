#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: concurrent widgets can mix suggestion records, and malformed mode markers can skew counts.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-suggestion-history.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/tendencies"
printf '%s\n' 'mode=generate' 'unrecognized line' 'mode=' 'mode=fix' >"$tmp/tendencies/suggestions.log"
tendencies=$(LMLINE_CONFIG_DIR="$tmp/config" LMLINE_HISTORY_DIR="$tmp/tendencies" \
  "$repo_dir/lmline/lmline" history tendencies | sort) || fail "history tendencies command failed"
[[ $tendencies == $'fix=1\ngenerate=1\ntotal=2' ]] || fail "unexpected history tendencies: $tendencies"
ok "history tendencies count only nonempty modes"

# Exceed common shell stdio buffer sizes; one print call need not be one write.
printf -v padding '%8192s' ''
padding=${padding// /x}
mkdir "$tmp/bin"
cat >"$tmp/bin/dd" <<'DD'
#!/usr/bin/env bash
# Bash has opened the append fd. Let writer 2 finish, then writer 3 waits for us.
: >"$LMLINE_HISTORY_DIR/start-peers" || exit 1
await done-2
exec "$LMLINE_TEST_DD" "$@"
DD
chmod +x "$tmp/bin/dd"
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
if [[ $2 == bash ]]; then
  if [[ $writer == 1 ]]; then
    LMLINE_TEST_DD=$(type -P dd)
    export LMLINE_TEST_DD
    export -f await
    export PATH="${BASH_SOURCE[0]%/*}/bin:$PATH"
  fi
  record_suggestion=__lmline_record_suggestion
else
  print() {
    builtin print "$@" || return
    # A split append must let writer 2 finish between writer 1's fields.
    if [[ $writer == 1 && $# == 1 && $1 == id=* && $1 != *$'\n'* ]]; then
      : >"$LMLINE_HISTORY_DIR/start-peers"
      await done-2
    fi
  }
  record_suggestion=__lmline_zsh_record_suggestion
fi
if [[ $writer == 2 ]]; then
  await start-peers
elif [[ $writer == 3 ]]; then
  await done-1
fi
"$record_suggestion" generate "original $writer-$padding" "candidate $writer-$padding"
: >"$LMLINE_HISTORY_DIR/done-$writer"
# With a full-record zsh append, no standalone id print releases writer 2.
if [[ $2 == zsh && $writer == 1 ]]; then
  : >"$LMLINE_HISTORY_DIR/start-peers"
fi
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
    function bad() {
      line = NR
      # Report only known field names and lengths, never values.
      actual = "(unrecognized field)"
      if (match($0, /^(id|timestamp|cwd|mode|original|candidate)=/)) actual = substr($0, 1, RLENGTH)
      actual = actual " (" length($0) " bytes)"
    }
    BEGIN {
      sep = (shell == "bash" ? "\\ " : " ")
      original = "original=original" sep
      candidate = "candidate=candidate" sep
      split("id= timestamp= cwd= mode=generate original= candidate=", fields)
    }
    line { next }
    NR > 18 { bad(); next }
    NR % 6 == 1 { if ($0 !~ /^id=.+$/) bad() }
    NR % 6 == 2 { if ($0 !~ /^timestamp=.+$/) bad() }
    NR % 6 == 3 { if ($0 !~ /^cwd=.+$/) bad() }
    NR % 6 == 4 { if ($0 != "mode=generate") bad() }
    NR % 6 == 5 {
      pair = substr($0, length(original) + 1)
      if ($0 != original pair || pair !~ /^[123]-/ || substr(pair, 3) != pad || seen[pair]++) bad()
    }
    NR % 6 == 0 { if ($0 != candidate pair) bad() }
    END {
      if (!line && NR == 18) exit
      if (!line) {
        line = NR + 1
        actual = "(end of file)"
      }
      expected = (line > 18 ? "(end of file)" : fields[(line - 1) % 6 + 1])
      printf "suggestions.log: %d lines\n", NR
      printf "first offending line %d: expected %s, got %s\n", line, expected, actual
      exit 1
    }
  ' "$history_dir/suggestions.log" >&2 ||
    fail "$shell suggestion records interleaved or mismatched"
  ok "$shell suggestion history keeps concurrent records intact"
done
