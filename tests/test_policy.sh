#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

bash -c '
  set -euo pipefail
  source "$1/lmline/context.bash"
  source "$1/lmline/actions.bash"
  source "$1/lmline/policy.bash"
  [[ $(__lmline_risk_level "echo hello") == low ]]
  [[ $(__lmline_risk_level "rm -rf build") == high ]]
  [[ $(__lmline_risk_level "rm  -rf build") == high ]]
  [[ $(__lmline_risk_level "pkill firefox") == high ]]
  [[ $(__lmline_risk_level "echo hi > out.txt") == medium ]]
  [[ $(__lmline_risk_reason "rm -rf build") == "recursive remove" ]]
  __lmline_validate_candidate "printf '\''%s\n'\'' hello"
  __lmline_validate_candidate "curl -Ls '\''https://localhost/data.csv'\'' | awk -F, '\''NR>1 {c=\$2+0; if(c>max) max=c} END{print max}'\''"
  __lmline_validate_candidate "curl -s '\''https://api.example.com/data'\'' | jq -r '\''.data.value'\''"
  [[ $(__lmline_candidate_rejection_reason "curl https://weather.invalid/current?key=YOUR_API_KEY") == "ok" ]]
  [[ $(__lmline_candidate_rejection_reason "printf hi | FOO=bar") == "env-only-command-segment" ]]
  [[ $(__lmline_candidate_rejection_reason "wc $1") == "directory-file-operand" ]]
  [[ $(__lmline_candidate_rejection_reason "## captured" fix) == "fix-heading" ]]
  [[ $(__lmline_candidate_rejection_reason "exit_status=2" fix) == "fix-status" ]]
  long_candidate=$(printf "printf %%s "; printf "a%.0s" {1..5000})
  [[ ${#long_candidate} -gt 4096 ]]
  truncated_candidate=$(printf "%s\n" "$long_candidate" | __lmline_valid_candidates)
  [[ -n "$truncated_candidate" ]]
  [[ ${#truncated_candidate} == 4096 ]]
  LMLINE_MAX_CANDIDATE_BYTES=8192
  printf "%s\n" "$long_candidate" | __lmline_valid_candidates | grep -Fxq "$long_candidate"
  LMLINE_MAX_CANDIDATE_BYTES=4096
  broken_long_candidate=$(printf "printf %%s '\''"; printf "b%.0s" {1..5000}; printf "'\''")
  broken_truncated_candidate=$(printf "%s\n" "$broken_long_candidate" | __lmline_valid_candidates)
  [[ "$broken_truncated_candidate" == "# TRUNCATED: "* ]]
  [[ ${#broken_truncated_candidate} == 4096 ]]
  ! __lmline_split_inline_comment "curl http://x.com#frag" >/dev/null 2>&1
  mapfile -t inline_parts < <(__lmline_split_inline_comment "curl http://x.com#frag # fetch")
  [[ ${inline_parts[0]} == "curl http://x.com#frag " ]]
  [[ ${inline_parts[1]} == " fetch" ]]
  ! __lmline_split_inline_comment "echo '\''hello # world'\''" >/dev/null 2>&1
  ! __lmline_split_inline_comment "echo \"hello # world\"" >/dev/null 2>&1
  mapfile -t inline_head < <(__lmline_split_inline_comment "# generate something")
  [[ ${inline_head[0]} == "" ]]
  [[ ${inline_head[1]} == " generate something" ]]
  ! __lmline_validate_candidate "tail -n 10 $1"
  __lmline_validate_candidate "find $1 -maxdepth 1 -type f | head"
  ! __lmline_validate_candidate "printf hi | FOO=bar"
  ! __lmline_validate_candidate $'"'"'echo bad\nwhoami'"'"'
  fence_filtered=$(printf "%s\n" "$(printf "\140\140\140bash")" "$(printf "  \140\140\140sh  ")" "$(printf "echo '\''\140\140\140'\''")" | __lmline_valid_candidates)
  ! grep -q "^$(printf "\140\140\140bash")$" <<<"$fence_filtered"
  ! grep -q "^$(printf "\140\140\140sh")$" <<<"$fence_filtered"
  grep -q "^$(printf "echo '\''\140\140\140'\''")$" <<<"$fence_filtered"
  filtered=$(printf "%s\n" "Here is a command:" "1. echo one" "2. pwd" "definitely-not-a-command-for-lmline" | __lmline_valid_candidates)
  grep -q "^echo one$" <<<"$filtered"
  grep -q "^pwd$" <<<"$filtered"
  ! grep -q "Here is" <<<"$filtered"
  ! grep -q "definitely-not" <<<"$filtered"
  context_tmp=$(mktemp "${TMPDIR:-/tmp}/lmline-context.XXXXXX")
  __lmline_context_file "$context_tmp" "# test"
  context_shell=$(cat "$context_tmp")
  rm -f "$context_tmp"
  grep -q "^bash=" <<<"$context_shell"
  grep -q "^ostype=" <<<"$context_shell"
  project_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-project.XXXXXX")
  (cd "$project_tmp" && touch Cargo.toml && __lmline_project_type | grep -q rust)
  marker_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-marker.XXXXXX")
  printf "custom\t.marker\n" >"$marker_tmp/project_markers.tsv"
  (cd "$marker_tmp" && touch .marker && LMLINE_USER_RULES_DIR="$marker_tmp"; __lmline_project_type | grep -q custom)
  rm -rf "$marker_tmp"
  rm -rf "$project_tmp"
' _ "$repo_dir" || fail "policy/context"
ok "policy and context"
