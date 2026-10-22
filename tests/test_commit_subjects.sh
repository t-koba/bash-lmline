#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the commit-subject check accepts the subjects the rule allows and
# rejects the ones it forbids, on a temporary history and on this repository.

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

rule_repo() {
  local dir=$1
  new_repo "$dir"
  mkdir -p "$dir/scripts"
  printf '#!/usr/bin/env bash\n' >"$dir/scripts/check-commit-subjects.sh"
  commit_in "$dir" "Add the commit subject check"
}

# A subject that follows the rule is accepted.
repo=$work/compliant
rule_repo "$repo"
commit_in "$repo" "Check the commit subjects against the rule"
if ! bash "$checker" "$repo" >"$work/compliant.out" 2>"$work/compliant.err"; then
  fail "the check rejected a subject that follows the rule: $(cat "$work/compliant.err")"
fi
grep -q 'ok' "$work/compliant.out" || fail "the check did not report ok for a compliant history"

# A subject that the rule allows is accepted: a lowercase imperative and
# a plain date are not internal identifiers.
repo=$work/allowed
rule_repo "$repo"
commit_in "$repo" "keep the sign-in reason"
commit_in "$repo" "Bump the pinned download date to 20261021"
commit_in "$repo" "Update the widget: the frame too"
if ! bash "$checker" "$repo" >"$work/allowed.out" 2>"$work/allowed.err"; then
  fail "the check rejected a subject the rule allows: $(cat "$work/allowed.err")"
fi

# A commit that predates the rule keeps its own subject.
repo=$work/legacy
new_repo "$repo"
commit_in "$repo" "feat: add the thing."
mkdir -p "$repo/scripts"
printf '#!/usr/bin/env bash\n' >"$repo/scripts/check-commit-subjects.sh"
commit_in "$repo" "Add the commit subject check"
commit_in "$repo" "Check the commit subjects against the rule"
if ! bash "$checker" "$repo" >"$work/legacy.out" 2>&1; then
  fail "the check rejected a commit that predates the rule"
fi

violation_case() {
  local label=$1 subject=$2 reason=$3
  local repo="$work/$label"
  rule_repo "$repo"
  commit_in "$repo" "$subject"
  if bash "$checker" "$repo" >"$work/$label.out" 2>"$work/$label.err"; then
    fail "the check accepted the subject: $subject"
  fi
  grep -q "$reason" "$work/$label.err" \
    || fail "the check did not report the reason for the subject: $subject"
}

violation_case prefix "fix: repair the widget" "label prefix"
violation_case otherprefix "wip: repair the widget" "label prefix"
violation_case scopedprefix "feat(engine): repair the widget" "label prefix"
violation_case sentences "Keep the token fresh. Also renew it" "more than one sentence"
violation_case hex "Wait for the answer deadbeef12" "hex identifier"
violation_case hexliteral "Fix the 0xdeadbeef mask" "hex identifier"
violation_case shorthash "Revert fee232d" "hex identifier"
violation_case shorthash2 "Apply the fix from 42345d9" "hex identifier"
violation_case item "Close the item wi_1e2b2bb2a755d6a0" "internal identifier"

# A truncated history is reported instead of a history the check cannot read.
source_repo=$work/shallow-source
rule_repo "$source_repo"
commit_in "$source_repo" "Check the commit subjects against the rule"
shallow=$work/shallow
if ! git clone -q --depth 1 "file://$source_repo" "$shallow" 2>/dev/null; then
  fail "could not clone a shallow copy of the temporary repository"
fi
if bash "$checker" "$shallow" >"$work/shallow.out" 2>"$work/shallow.err"; then
  fail "the check passed a repository with a truncated history"
fi
grep -q 'truncated' "$work/shallow.err" \
  || fail "the check did not report the truncated history: $(cat "$work/shallow.err")"

# A history without a subject to check is not a success.
repo=$work/empty
rule_repo "$repo"
if bash "$checker" "$repo" >"$work/empty.out" 2>"$work/empty.err"; then
  fail "the check passed a history without a subject to check"
fi
grep -q 'no commit subject was checked' "$work/empty.err" \
  || fail "the check did not report that no subject was checked: $(cat "$work/empty.err")"

# A directory without a repository is skipped, not failed.
plain=$work/plain
mkdir -p "$plain"
if ! bash "$checker" "$plain" >"$work/plain.out" 2>&1; then
  fail "the check failed on a directory without a repository"
fi
grep -q 'skipped' "$work/plain.out" || fail "the check did not report the skip"

# This repository keeps the rule.
if ! bash "$checker" >"$work/self.out" 2>"$work/self.err"; then
  fail "the check rejected this repository: $(cat "$work/self.err")"
fi

ok "the commit subject check accepts and rejects as the rule says"
