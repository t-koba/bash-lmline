#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=lmline/policy.bash
source "$repo_dir/lmline/policy.bash"

check_hash() {
  local candidate=$1 expected=$2 actual
  bash -n -c "$candidate" || fail "invalid Bash fixture: $candidate"
  actual=$(__lmline_candidate_rejection_reason "$candidate" rewrite bash)
  [[ "$actual" == "$expected" ]] || fail "Bash hash policy: $actual, expected $expected: $candidate"
}

check_hash 'hash -p /nonexistent ls; ls' command-not-found
check_hash 'hash -p /nonexistent ls printf; ls' command-not-found
check_hash 'hash -r; ls' command-not-found
check_hash 'hash -d ls; ls' command-not-found
check_hash 'hash' ok
check_hash 'hash -l' ok
check_hash 'command hash -p /nonexistent ls; ls' command-not-found
check_hash "bash -c 'hash -p /nonexistent ls; ls'" command-not-found

hash_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-hash-policy.XXXXXX")
trap 'rm -rf "$hash_tmp"' EXIT
marker=$hash_tmp/executed
check_hash "hash -p /nonexistent touch; touch '$marker'" command-not-found
[[ ! -e "$marker" ]] || fail "Bash hash validation executed candidate text"

ok "Bash hash override and non-execution"
