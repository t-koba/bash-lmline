#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the charter commit-subject check accepts the subjects the charter
# allows and rejects the ones it forbids, on a temporary history and on this
# repository.

checker="$repo_dir/scripts/check-commit-subjects.sh"

if ! command -v git >/dev/null 2>&1; then
  ok "commit subject check (skipped: git is not installed)"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-subjects.XXXXXX")
trap 'rm -rf "$work"' EXIT

new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q 2>/dev/null || fail "could not create a temporary repository"
}

commit_in() {
  local dir=$1 subject=$2
  printf 'content\n' >>"$dir/file.txt"
  git -C "$dir" add -A
  GIT_AUTHOR_NAME=lmline GIT_AUTHOR_EMAIL=lmline@example.invalid \
    GIT_COMMITTER_NAME=lmline GIT_COMMITTER_EMAIL=lmline@example.invalid \
    git -C "$dir" -c commit.gpgsign=false commit -q -m "$subject" \
    || fail "could not commit in the temporary repository"
}

charter_repo() {
  local dir=$1
  new_repo "$dir"
  printf '# lmline: charter\n' >"$dir/PROJECT.md"
  commit_in "$dir" "Record the project charter in the repository"
}

# A subject that follows the charter is accepted.
repo=$work/compliant
charter_repo "$repo"
commit_in "$repo" "Check the commit subjects against the charter"
if ! bash "$checker" "$repo" >"$work/compliant.out" 2>"$work/compliant.err"; then
  fail "the check rejected a subject that follows the charter: $(cat "$work/compliant.err")"
fi
grep -q 'ok' "$work/compliant.out" || fail "the check did not report ok for a compliant history"

# A commit that predates the charter keeps its own subject.
repo=$work/legacy
new_repo "$repo"
commit_in "$repo" "feat: add the thing."
printf '# lmline: charter\n' >"$repo/PROJECT.md"
commit_in "$repo" "Record the project charter in the repository"
commit_in "$repo" "Check the commit subjects against the charter"
if ! bash "$checker" "$repo" >"$work/legacy.out" 2>&1; then
  fail "the check rejected a commit that predates the charter"
fi

violation_case() {
  local label=$1 subject=$2 reason=$3
  local repo="$work/$label"
  charter_repo "$repo"
  commit_in "$repo" "$subject"
  if bash "$checker" "$repo" >"$work/$label.out" 2>"$work/$label.err"; then
    fail "the check accepted the subject: $subject"
  fi
  grep -q "$reason" "$work/$label.err" \
    || fail "the check did not report the reason for the subject: $subject"
}

violation_case prefix "fix: repair the widget" "conventional-commit prefix"
violation_case lowercase "keep the sign-in reason" "capital letter"
violation_case sentences "Keep the token fresh. Also renew it" "more than one sentence"
violation_case hex "Wait for the answer deadbeef12" "hex identifier"
violation_case item "Close the item wi_1e2b2bb2a755d6a0" "internal identifier"
violation_case harness "Record the mizu harness state" "internal identifier"

# A directory without a repository is skipped, not failed.
plain=$work/plain
mkdir -p "$plain"
if ! bash "$checker" "$plain" >"$work/plain.out" 2>&1; then
  fail "the check failed on a directory without a repository"
fi
grep -q 'skipped' "$work/plain.out" || fail "the check did not report the skip"

# This repository keeps the charter rule.
if ! bash "$checker" >"$work/self.out" 2>"$work/self.err"; then
  fail "the check rejected this repository: $(cat "$work/self.err")"
fi

ok "the charter commit subject check accepts and rejects as the charter says"
