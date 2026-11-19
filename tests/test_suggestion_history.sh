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
# Bash has opened the append fd. Keep the peers concurrent while it is open.
# One record must be one dd invocation: a second call can interleave fields.
printf x >>"$LMLINE_HISTORY_DIR/dd-calls" || exit 1
: >"$LMLINE_HISTORY_DIR/start-peers" || exit 1
await done-2
await done-3
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
  record_suggestion=__lmline_zsh_record_suggestion
fi
if [[ $writer != 1 ]]; then
  await start-peers
fi
"$record_suggestion" generate "original $writer-$padding" "candidate $writer-$padding"
: >"$LMLINE_HISTORY_DIR/done-$writer"
# A full-record zsh append has no per-field hook; release the peers here.
if [[ $2 == zsh && $writer == 1 ]]; then
  : >"$LMLINE_HISTORY_DIR/start-peers"
fi
WRITER

# A bounded retry absorbs a one-off runner/filesystem append artifact. Every
# attempt reruns the same assertions with a fresh history directory, config
# directory and output files, so a deterministic defect still fails at the end.
concurrent_failure=
concurrent_diagnostic=
check_concurrent_records() {
  local shell=$1 history_dir=$2 out_prefix=$3 config_dir=$4
  local flags=(-f -e -i)
  [[ $shell != bash ]] || flags=(--norc -e -i)
  mkdir -m 700 "$history_dir"
  local pids=() pid writer failed=0
  for writer in 1 2 3; do
    LMLINE_CONFIG_DIR="$config_dir" LMLINE_HISTORY_DIR="$history_dir" LMLINE_BIND_KEYS=0 \
      "$shell" "${flags[@]}" -c 'source "$@"' _ "$tmp/writer" "$repo_dir" "$shell" "$writer" "$padding" \
      >"$out_prefix-$writer.out" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  if ((failed)); then
    concurrent_diagnostic=$(cat "$out_prefix"-*.out 2>&1)
    [[ -z $concurrent_diagnostic ]] || printf '%s\n' "$concurrent_diagnostic" >&2
    concurrent_failure="$shell suggestion writers did not finish"
    return 1
  fi
  if [[ $shell == bash ]]; then
    # BSD wc pads its count; compare numerically, not as text.
    local append_calls
    append_calls=$(wc -c <"$history_dir/dd-calls")
    if ((append_calls != 1)); then
      concurrent_failure="bash suggestion record used more than one append"
      concurrent_diagnostic="dd-calls: $append_calls"
      return 1
    fi
  fi
  # Check the six fields in order and exactly one original/candidate pair per writer.
  local diagnostic
  if ! diagnostic=$(awk -v pad="$padding" -v shell="$shell" '
    function bad() {
      line = NR
      # Report only known field names and lengths, never values.
      actual = "(unrecognized field)"
      if (match($0, /^(id|timestamp|cwd|mode|original|candidate)=/)) actual = substr($0, 1, RLENGTH)
      copy = $0
      n_id = gsub(/id=/, "", copy)
      copy = $0
      n_ts = gsub(/timestamp=/, "", copy)
      copy = $0
      n_orig = gsub(/original=/, "", copy)
      copy = $0
      n_cand = gsub(/candidate=/, "", copy)
      actual = actual " (" length($0) " bytes; markers id=" n_id " ts=" n_ts " orig=" n_orig " cand=" n_cand ")"
    }
    BEGIN {
      # Both shells shell-quote the space in the padded field.
      sep = "\\ "
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
  ' "$history_dir/suggestions.log" 2>&1); then
    concurrent_failure="$shell suggestion records interleaved or mismatched"
    concurrent_diagnostic=$diagnostic
    return 1
  fi
  return 0
}

for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null; then
    printf 'skip - %s suggestion history (shell unavailable)\n' "$shell"
    continue
  fi
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    history_dir="$tmp/history-$shell-attempt$attempt"
    if check_concurrent_records "$shell" "$history_dir" \
      "$tmp/$shell-attempt$attempt" "$tmp/config-$shell-attempt$attempt"; then
      break
    fi
    if ((attempt >= 3)); then
      [[ -z $concurrent_diagnostic ]] || printf '%s\n' "$concurrent_diagnostic" >&2
      fail "$concurrent_failure"
    fi
    printf 'retry - %s suggestion history attempt %d of 3 failed: %s\n' \
      "$shell" "$attempt" "$concurrent_failure" >&2
    [[ -z $concurrent_diagnostic ]] || printf '%s\n' "$concurrent_diagnostic" >&2
  done
  ok "$shell suggestion history keeps concurrent records intact"
done

# Zsh must keep shell-quoted newlines and backslashes escaped in the record;
# reinterpreting them would add a stray physical line to the history log.
if command -v zsh >/dev/null; then
  escapes_dir=$tmp/escapes-zsh
  mkdir -m 700 "$escapes_dir"
  original=$'line1\nline2\\tail'
  escaped=$(zsh -f -c 'print -r -- ${(q)1}' _ "$original") ||
    fail "zsh quoting helper failed"
  LMLINE_CONFIG_DIR=$tmp/config-escapes-zsh LMLINE_HISTORY_DIR=$escapes_dir LMLINE_BIND_KEYS=0 \
    zsh -f -e -i -c 'source "$1/lmline/init.zsh"; __lmline_zsh_record_suggestion generate "$2" "$3"' \
    _ "$repo_dir" "$original" candidate-plain >"$tmp/escapes-zsh.out" 2>&1 ||
    { cat "$tmp/escapes-zsh.out" >&2; fail "zsh escaped suggestion writer failed"; }
  mapfile -t escaped_lines <"$escapes_dir/suggestions.log"
  [[ ${#escaped_lines[@]} == 6 ]] ||
    fail "zsh suggestion record has ${#escaped_lines[@]} lines, expected 6"
  [[ ${escaped_lines[4]} == "original=$escaped" ]] ||
    fail "zsh suggestion record lost its escaped newline or backslash"
  [[ ${escaped_lines[5]} == candidate=candidate-plain ]] ||
    fail "zsh suggestion record misplaced the candidate"
  ok "zsh keeps escaped newlines and backslashes in one suggestion record"
fi

# Privacy helpers must establish the mode before the append. The fake dd
# checks the log mode at append time, so a record can only appear if the
# tightening happened first.
mkdir -p "$tmp/private-bin"
cat >"$tmp/private-bin/dd" <<'DD'
#!/usr/bin/env bash
mode=$(stat -c %a "$LMLINE_HISTORY_DIR/suggestions.log" 2>/dev/null || stat -f %Lp "$LMLINE_HISTORY_DIR/suggestions.log") || exit 1
[[ $mode == 600 || $mode == 0600 ]] || exit 1
exec "$LMLINE_TEST_DD" "$@"
DD
chmod +x "$tmp/private-bin/dd"
cat >"$tmp/private-writer" <<'PRIVATE_WRITER'
source "$1/lmline/init.$2"
if [[ $2 == bash ]]; then
  __lmline_record_suggestion generate original-private candidate-private
else
  __lmline_zsh_record_suggestion generate original-private candidate-private
fi
PRIVATE_WRITER

private_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

private_record() {
  local shell=$1 history_dir=$2 record_suggestions=${3-1}
  local flags=(-f -e -i)
  [[ $shell != bash ]] || flags=(--norc -e -i)
  LMLINE_TEST_DD=$(type -P dd) PATH="$tmp/private-bin:$PATH" \
    LMLINE_CONFIG_DIR="$tmp/config-private-$shell" LMLINE_HISTORY_DIR="$history_dir" LMLINE_BIND_KEYS=0 \
    LMLINE_RECORD_SUGGESTIONS="$record_suggestions" \
    "$shell" "${flags[@]}" -c 'source "$@"' _ "$tmp/private-writer" "$repo_dir" "$shell" \
    >"$tmp/private-$shell.out" 2>&1 || {
      cat "$tmp/private-$shell.out" >&2
      fail "$shell private suggestion writer failed"
    }
}

for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null; then
    printf 'skip - %s private suggestion history (shell unavailable)\n' "$shell"
    continue
  fi

  history_dir="$tmp/private-log-$shell"
  mkdir -m 700 "$history_dir"
  : >"$history_dir/suggestions.log"
  chmod 666 "$history_dir/suggestions.log"
  private_record "$shell" "$history_dir"
  grep -q '^candidate=candidate-private$' "$history_dir/suggestions.log" ||
    fail "$shell did not record after tightening a loose log"
  [[ $(private_mode "$history_dir/suggestions.log") == 600 ]] ||
    fail "$shell left the suggestion log world-writable"
  ok "$shell tightens a loose suggestion log before recording"

  # A legitimate relative directory beginning with a dash must not be parsed
  # as an option by the directory utilities in either shell.
  dash_dir="-history-$shell"
  (cd "$tmp" && private_record "$shell" "$dash_dir") || {
    cat "$tmp/private-$shell.out" >&2
    fail "$shell private writer failed in dash-leading history directory"
  }
  grep -q '^candidate=candidate-private$' "$tmp/$dash_dir/suggestions.log" ||
    fail "$shell did not record in a dash-leading history directory"
  [[ $(private_mode "$tmp/$dash_dir") == 700 ]] ||
    fail "$shell left a dash-leading history directory non-private"
  ok "$shell records in a dash-leading relative history directory"

  # A linked ancestor is allowed (macOS /tmp relies on this); only the final
  # component must be a real private directory.
  ancestor_real="$tmp/private-ancestor-$shell"
  ancestor_link="$tmp/private-ancestor-link-$shell"
  mkdir -m 700 "$ancestor_real"
  ln -s "$ancestor_real" "$ancestor_link"
  private_record "$shell" "$ancestor_link/history"
  grep -q '^candidate=candidate-private$' "$ancestor_real/history/suggestions.log" ||
    fail "$shell did not record through a linked ancestor"
  [[ $(private_mode "$ancestor_real/history") == 700 ]] ||
    fail "$shell left a directory under a linked ancestor non-private"
  ok "$shell records through a linked ancestor with a private final directory"

  history_dir="$tmp/private-symlink-$shell"
  mkdir -m 700 "$history_dir"
  canary="$tmp/private-canary-$shell"
  printf 'canary-only\n' >"$canary"
  ln -s "$canary" "$history_dir/suggestions.log"
  private_record "$shell" "$history_dir"
  [[ -L "$history_dir/suggestions.log" ]] || fail "$shell replaced a suggestion log symlink"
  [[ $(readlink "$history_dir/suggestions.log") == "$canary" ]] ||
    fail "$shell changed a suggestion log symlink target"
  grep -q '^canary-only$' "$canary" || fail "$shell truncated a symlink target"
  ! grep -q '^id=' "$canary" || fail "$shell wrote a record through a symlink"
  ok "$shell refuses to record through a suggestion log symlink"

  history_dir="$tmp/private-history-symlink-$shell"
  target="$tmp/private-history-target-$shell"
  mkdir -m 700 "$target"
  ln -s "$target" "$history_dir"
  private_record "$shell" "$history_dir"
  [[ -L "$history_dir" ]] || fail "$shell replaced a history directory symlink"
  [[ $(readlink "$history_dir") == "$target" ]] || fail "$shell changed a history directory symlink target"
  [[ ! -e "$target/suggestions.log" ]] || fail "$shell wrote a record into a symlinked history directory"
  ! grep -q '^id=' "$target/suggestions.log" 2>/dev/null || fail "$shell wrote a record through a history directory symlink"
  ok "$shell refuses to record into a symlinked history directory"

  # A trailing slash resolves a symlink before [[ -L ]] can see it, so the
  # normalized path must be refused exactly like the plain one.
  target_mode=$(private_mode "$target") || fail "cannot read symlink target mode"
  for slashes in / ///; do
    private_record "$shell" "$history_dir$slashes"
    [[ -L "$history_dir" ]] || fail "$shell replaced a history directory symlink with trailing slashes"
    [[ $(readlink "$history_dir") == "$target" ]] || fail "$shell changed a history directory symlink target with trailing slashes"
    [[ ! -e "$target/suggestions.log" ]] || fail "$shell wrote a record into a symlinked history directory with trailing slashes"
    ! grep -q '^id=' "$target/suggestions.log" 2>/dev/null || fail "$shell wrote a record through a history directory symlink with trailing slashes"
    [[ $(private_mode "$target") == "$target_mode" ]] || fail "$shell changed a symlink target's mode with trailing slashes"
  done
  ok "$shell refuses to record into a symlinked history directory with trailing slashes"

  # A dot component after the symlink resolves it before [[ -L ]] can see it;
  # every such spelling must be refused without touching the target.
  target_mode=$(private_mode "$target") || fail "cannot read symlink target mode"
  for dot_form in "$history_dir/." "$history_dir/./" "$history_dir/../${target##*/}"; do
    private_record "$shell" "$dot_form"
    [[ -L "$history_dir" ]] || fail "$shell replaced a history directory symlink with a dot component"
    [[ $(readlink "$history_dir") == "$target" ]] || fail "$shell changed a history directory symlink target with a dot component"
    [[ ! -e "$target/suggestions.log" ]] || fail "$shell wrote a record into a symlinked history directory with a dot component"
    ! grep -q '^id=' "$target/suggestions.log" 2>/dev/null || fail "$shell wrote a record through a history directory symlink with a dot component"
    [[ $(private_mode "$target") == "$target_mode" ]] || fail "$shell changed a symlink target's mode with a dot component"
  done
  ok "$shell refuses to record into a symlinked history directory via dot components"

  parent="$tmp/private-blocked-$shell"
  mkdir -m 700 "$parent"
  mkdir -m 500 "$parent/no-write"
  # A privileged runner can still create the directory; do not claim a check
  # the fixture cannot make.
  if mkdir "$parent/no-write/probe" 2>/dev/null; then
    rmdir "$parent/no-write/probe"
    printf 'skip - %s unwritable parent (parent is writable here)\n' "$shell"
    continue
  fi
  history_dir="$parent/no-write/history"
  private_record "$shell" "$history_dir"
  [[ ! -e "$history_dir/suggestions.log" ]] || fail "$shell recorded into an unwritable parent"
  ok "$shell writes no record when the history directory cannot be established"
done

# Opt-out must be exact: only 0 stops recording. Empty or other non-0 values
# must keep today's behavior.
for shell in bash zsh; do
  if ! command -v "$shell" >/dev/null; then
    printf 'skip - %s suggestion history opt-out (shell unavailable)\n' "$shell"
    continue
  fi

  history_dir="$tmp/opt-out-$shell"
  mkdir -m 700 "$history_dir"
  private_record "$shell" "$history_dir" 0
  [[ ! -e "$history_dir/suggestions.log" ]] ||
    fail "$shell recorded a suggestion with LMLINE_RECORD_SUGGESTIONS=0"
  ok "$shell skips suggestion history when recording is disabled"

  for value in '' false 00; do
    history_dir="$tmp/keep-recording-$shell-${value:-empty}"
    mkdir -m 700 "$history_dir"
    private_record "$shell" "$history_dir" "$value"
    grep -q '^candidate=candidate-private$' "$history_dir/suggestions.log" ||
      fail "$shell stopped recording for LMLINE_RECORD_SUGGESTIONS='$value'"
  done
  ok "$shell keeps recording unless the opt-out is exactly 0"
done
