#!/usr/bin/env bash
# Check the commit subjects that follow the charter against the charter rule:
# one plain imperative sentence describing the change, with no internal
# identifier. The rule starts at the commit that added PROJECT.md, so the
# commits before the charter keep the subjects they already have.
#
# Usage: check-commit-subjects.sh [repo_dir]
# Without an argument the repository that holds this script is checked.
# Exit status: 0 when every checked subject follows the rule, 1 when one
# does not, 2 for a wrong usage. A repository without a usable git history
# is skipped and reported as skipped.
set -euo pipefail

script_name=${0##*/}

usage() {
  printf 'usage: %s [repo_dir]\n' "$script_name"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if (( $# > 1 )); then
  usage >&2
  exit 2
elif (( $# == 1 )); then
  repo_dir=$1
else
  repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi

if ! command -v git >/dev/null 2>&1; then
  printf 'check-commit-subjects: skipped: git is not installed\n'
  exit 0
fi

if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
  printf 'check-commit-subjects: skipped: %s holds no git repository\n' "$repo_dir"
  exit 0
fi

if ! git -C "$repo_dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  printf 'check-commit-subjects: skipped: the repository holds no commit\n'
  exit 0
fi

charter=$(git -C "$repo_dir" log --diff-filter=A --format=%H -- PROJECT.md 2>/dev/null | tail -n 1) || charter=''
if [[ -z "$charter" ]]; then
  printf 'check-commit-subjects: no charter commit found; PROJECT.md was never added\n' >&2
  exit 1
fi
if ! git -C "$repo_dir" merge-base --is-ancestor "$charter" HEAD; then
  printf 'check-commit-subjects: the charter commit %s is not an ancestor of HEAD\n' "${charter:0:12}" >&2
  exit 1
fi

# Print the reason why a subject does not follow the charter, or nothing when
# it does.
subject_problem() {
  local subject=$1
  if [[ -z "$subject" ]]; then
    printf 'the subject is empty'
  elif [[ "$subject" =~ ^(feat|fix|chore|docs|refactor|style|perf|test|tests|build|ci|release|revert)(\([[:alnum:]_/.-]+\))?!?: ]]; then
    printf 'the subject starts with a conventional-commit prefix'
  elif [[ ! "$subject" =~ ^[A-Z] ]]; then
    printf 'the subject does not start with a capital letter'
  elif [[ "$subject" == *". "* ]]; then
    printf 'the subject carries more than one sentence'
  elif [[ "$subject" =~ (^|[^[:alnum:]_])(wi_[[:alnum:]]+|mizu)([^[:alnum:]_]|$) ]]; then
    printf 'the subject carries an internal identifier'
  elif [[ "$subject" =~ [0-9a-fA-F]{8,} ]]; then
    printf 'the subject carries a hex identifier'
  fi
}

checked=0
violations=0
while IFS=$'\t' read -r commit subject; do
  checked=$((checked + 1))
  problem=$(subject_problem "$subject")
  if [[ -n "$problem" ]]; then
    violations=$((violations + 1))
    printf 'check-commit-subjects: %s: %s\n' "${commit:0:12}" "$problem" >&2
    printf 'check-commit-subjects: subject: %s\n' "$subject" >&2
  fi
done < <(git -C "$repo_dir" log --format='%H%x09%s' "$charter"..HEAD)

if (( violations > 0 )); then
  printf 'check-commit-subjects: %s of %s commit subjects do not follow the charter\n' "$violations" "$checked" >&2
  exit 1
fi

printf 'check-commit-subjects: ok (%s commit subjects checked)\n' "$checked"
