#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: the privacy scan finds the private data the charter keeps out of
# public files, and leaves the public content of a tree alone.

scanner="$repo_dir/scripts/privacy-scan.sh"

if ! command -v rg >/dev/null 2>&1; then
  ok "privacy scan (skipped: rg is not installed)"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-privacy.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The private strings are assembled at run time, so that this file does not
# hold the very strings the scan looks for.
home_root='/ho''me'
private_address="192.168.""0"".""5"
internal_host='build-box.'"inter""nal"
personal_address='writer@'"personalmail.net"
token_value='sk-'"abcdefghijklmnopqrstuvwxyz"
link_local='fe9'"0::1"
link_local_upper='FE9'"0::1"
lookalike_address="alice@example.""com.evil.net"

# A tree that holds public content only stays clean.
clean=$work/clean
mkdir -p "$clean"
printf 'base url https://api.openai.com\nloopback http://127.0.0.1:1234\naddress writer@example.com\n' \
  >"$clean/notes.txt"
if ! bash "$scanner" "$clean" >"$work/clean.out" 2>"$work/clean.err"; then
  fail "the scan rejected a clean tree: $(cat "$work/clean.err")"
fi
grep -q 'ok' "$work/clean.out" || fail "the scan did not report ok for a clean tree"

# The scan reads the tree it was given and not the directory the
# caller happens to be in.
elsewhere=$work/elsewhere
mkdir -p "$elsewhere"
if ! (cd "$elsewhere" && bash "$scanner" "$clean" >"$work/elsewhere.out" 2>"$work/elsewhere.err"); then
  fail "the scan rejected a clean tree when it ran from another directory: $(cat "$work/elsewhere.err")"
fi
if ! (cd "$elsewhere" && bash "$scanner" >"$work/elsewhere-repo.out" 2>"$work/elsewhere-repo.err"); then
  fail "the scan rejected this repository when it ran from another directory: $(cat "$work/elsewhere-repo.err")"
fi

# The exclusions belong to the scanned tree: the patterns the scanner
# holds and the git directory are not part of the published tree.
copy_tree=$work/copy
mkdir -p "$copy_tree/scripts" "$copy_tree/.git"
cp "$scanner" "$copy_tree/scripts/privacy-scan.sh"
printf 'base url https://api.openai.com\n' >"$copy_tree/notes.txt"
printf 'file %s/alice/notes.txt\n' "$home_root" >"$copy_tree/.git/FETCH_HEAD"
if ! bash "$scanner" "$copy_tree" >"$work/copy.out" 2>"$work/copy.err"; then
  fail "the scan reported what the scanned tree excludes: $(cat "$work/copy.err")"
fi

# A tree that holds one private thing is reported with the kind of thing.
finding_case() {
  local label=$1 reason=$2
  shift 2
  local dir="$work/$label"
  mkdir -p "$dir"
  printf '%s\n' "$*" >"$dir/notes.txt"
  if bash "$scanner" "$dir" >"$work/$label.out" 2>"$work/$label.err"; then
    fail "the scan accepted a tree that holds private data: $label"
  fi
  grep -q "$reason" "$work/$label.err" \
    || fail "the scan did not report the reason for the finding: $label"
}

finding_case localpath 'local path' "file $home_root/alice/notes.txt"
finding_case privateaddress 'private host name' "host $private_address"
finding_case internalthost 'private host name' "host $internal_host"
finding_case personaladdress 'personal address' "mail $personal_address"
finding_case credential 'credential-looking value' "token $token_value"
finding_case homepath 'local path' "cd $home_root/alice"
finding_case linklocal 'private host name' "host $link_local"
finding_case linklocalupper 'private host name' "host $link_local_upper"
finding_case mixedaddress 'personal address' "mail $personal_address and writer@example.com"
finding_case lookalike 'personal address' "mail $lookalike_address"

# A secret-like file name is reported as well.
secret_dir=$work/secretfile
mkdir -p "$secret_dir"
printf 'nothing here\n' >"$secret_dir/notes.key"
if bash "$scanner" "$secret_dir" >"$work/secretfile.out" 2>"$work/secretfile.err"; then
  fail "the scan accepted a tree that holds a secret-like file name"
fi
grep -q 'secret-like file name' "$work/secretfile.err" \
  || fail "the scan did not report the secret-like file name"

# Without ripgrep the scan fails closed instead of calling the tree clean.
no_rg_bin="$work/norg"
mkdir -p "$no_rg_bin"
bash_path=$(command -v bash) || fail "could not find bash"
ln -s "$bash_path" "$no_rg_bin/bash"
if PATH="$no_rg_bin" bash "$scanner" "$clean" >"$work/norg.out" 2>"$work/norg.err"; then
  fail "the scan passed a tree without ripgrep installed"
fi
grep -q 'rg is required for the privacy scan' "$work/norg.err" \
  || fail "the scan did not report the missing ripgrep"

# This repository holds no private data.
if ! bash "$scanner" >"$work/repo.out" 2>"$work/repo.err"; then
  fail "the scan rejected this repository: $(cat "$work/repo.err")"
fi

ok "the privacy scan finds private data and leaves public content alone"
