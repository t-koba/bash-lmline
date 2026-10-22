#!/usr/bin/env bash
# Check the commit subjects of this project against the rule the project
# states here: one plain imperative sentence describing the change, with no
# internal identifier. The rule starts at the commit that added this script,
# so the commits before it keep the subjects they already have.
#
# The check reads the history to find that commit, so it needs the whole
# history: a truncated clone is reported as an error, and a history that
# holds no subject to check is not reported as a success.
#
# Usage: check-commit-subjects.sh [repo_dir]
# Without an argument the repository that holds this script is checked.
# Exit status: 0 when every checked subject follows the rule, 1 when one
# does not, 2 for a wrong usage. A directory without a git repository, or
# one without a commit, is skipped and reported as skipped.
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

# A truncated history cannot show the commits that follow the rule, so
# the check reports it instead of passing a history it could not read.
if [[ "$(git -C "$repo_dir" rev-parse --is-shallow-repository 2>/dev/null || true)" == 'true' ]]; then
  printf 'check-commit-subjects: the history of %s is truncated (a shallow clone); the whole history is needed\n' "$repo_dir" >&2
  exit 1
fi

# The rule starts with the commit that added this script, so the history
# that does not hold it is reported instead of checked against a rule it
# never had.
rule_start=$(git -C "$repo_dir" log --diff-filter=A --format=%H -- scripts/check-commit-subjects.sh 2>/dev/null | tail -n 1) || rule_start=''
if [[ -z "$rule_start" ]]; then
  printf 'check-commit-subjects: the commit that added the rule was not found; scripts/check-commit-subjects.sh was never added\n' >&2
  exit 1
fi
if ! git -C "$repo_dir" merge-base --is-ancestor "$rule_start" HEAD; then
  printf 'check-commit-subjects: the rule commit %s is not an ancestor of HEAD\n' "${rule_start:0:12}" >&2
  exit 1
fi

# Print the reason why a subject does not follow the rule, or nothing when
# it does.
subject_problem() {
  local subject=$1 token
  if [[ -z "$subject" ]]; then
    printf 'the subject is empty'
  elif [[ "$subject" =~ ^[[:alnum:]][[:alnum:]_-]*(\([^()]*\))?!?: ]]; then
    # A subject that starts with a label is not one plain sentence, whatever
    # the label says.
    printf 'the subject starts with a label prefix'
  elif [[ "$subject" == *". "* ]]; then
    printf 'the subject carries more than one sentence'
  elif [[ "$subject" =~ (^|[^[:alnum:]_])wi_[[:alnum:]]+([^[:alnum:]_]|$) ]]; then
    printf 'the subject carries an internal identifier'
  elif [[ "$subject" =~ [0-9a-fA-F]{8,} ]]; then
    # A run of digits alone is a number or a date, not an identifier.
    token=${BASH_REMATCH[0]}
    if [[ "$token" == *[a-fA-F]* ]]; then
      printf 'the subject carries a hex identifier'
    fi
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
done < <(git -C "$repo_dir" log --format='%H%x09%s' "$rule_start"..HEAD)

if (( violations > 0 )); then
  printf 'check-commit-subjects: %s of %s commit subjects do not follow the rule\n' "$violations" "$checked" >&2
  exit 1
fi

if (( checked == 0 )); then
  printf 'check-commit-subjects: no commit subject was checked; the rule could not be verified\n' >&2
  exit 1
fi

printf 'check-commit-subjects: ok (%s commit subjects checked)\n' "$checked"
