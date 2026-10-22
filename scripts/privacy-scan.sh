#!/usr/bin/env bash
# Scan a tree for the private data this project keeps out of public files:
# local paths and user names, private host names, credential-looking values,
# personal addresses and secret-like file names.
#
# The patterns live in this script so that the publishing checklist and the
# publish check cannot drift apart. The script excludes itself, because it
# holds the patterns it looks for.
#
# Usage: privacy-scan.sh [dir]
# Without an argument the repository that holds this script is scanned.
# Exit status: 0 when the tree is clean, 1 when something is found, 2 for a
# wrong usage or a missing tool. The scan fails closed: without ripgrep it
# does not call the tree clean.
set -euo pipefail

script_name=${0##*/}

usage() {
  printf 'usage: %s [dir]\n' "$script_name"
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
  dir=$1
else
  dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi

if [[ ! -d "$dir" ]]; then
  printf 'privacy-scan: %s is not a directory\n' "$dir" >&2
  exit 2
fi

if ! command -v rg >/dev/null 2>&1; then
  printf 'privacy-scan: rg is required for the privacy scan; install ripgrep (https://github.com/BurntSushi/ripgrep)\n' >&2
  exit 2
fi

# The scan reads the tree it was given and not the directory the caller
# happens to be in: ripgrep matches its globs against the path relative
# to the working directory, so the scan runs from inside the tree.
if ! scan_root=$(cd -- "$dir" && pwd); then
  printf 'privacy-scan: %s cannot be read\n' "$dir" >&2
  exit 2
fi
dir=$scan_root
cd -- "$dir"

# A local path or a user name of the machine that wrote the file. The home
# directory of the root account is a local path as well.
path_pattern='(/Users/|/home/[^[:space:]/]+|/root/|/private/var/|[A-Za-z0-9._-]+\.local)'
# A host that only the writer's network reaches: a private network address
# or a name under an internal top-level domain. The link-local range is
# fe80::/10 and the unique-local range is fc00::/7.
host_pattern='((^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)|(fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|fe[89ab][0-9a-f]:)|[A-Za-z0-9-]+\.(internal|corp|lan|home|intranet|private)([^A-Za-z0-9-]|$))'
# A value that looks like a credential.
credential_pattern='(BEGIN .*PRIVATE|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
# A person's address. The reserved documentation domains are not user data.
address_pattern='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
reserved_domain='(^|\.)(example\.(com|net|org)|[A-Za-z0-9-]+\.(invalid|test|example|localhost))$'

scan_globs=(-uu --glob '!.git/**' --glob '!scripts/privacy-scan.sh' --glob '!request.md')

found=0

report() {
  local label=$1
  shift
  found=1
  printf 'privacy-scan: %s\n' "$label" >&2
  printf '%s\n' "$@" >&2
}

# Runs one pattern over the tree. Reports what it matched and returns 0;
# returns 2 when the scanner itself failed.
run_pattern() {
  local label=$1 pattern=$2 status=0 out
  shift 2
  out=$(rg -n --no-heading "$@" "$pattern" "${scan_globs[@]}" . 2>&1) || status=$?
  case "$status" in
    0)
      report "$label" "$(printf '%s\n' "$out" | sed 's|^\./||')"
      ;;
    1) ;;
    *)
      printf 'privacy-scan: the privacy scan failed (rg exit %s)\n%s\n' "$status" "$out" >&2
      exit 2
      ;;
  esac
}

run_pattern 'a local path or a user name found' "$path_pattern"
# A host name is written in either case.
run_pattern 'a private host name found' "$host_pattern" -i
run_pattern 'a credential-looking value found' "$credential_pattern"

# The addresses are taken out of the tree one by one, so that a personal
# address beside a documentation address on the same line is still found.
status=0
out=$(rg -n -o --no-heading "$address_pattern" "${scan_globs[@]}" . 2>&1) || status=$?
case "$status" in
  0)
    out=$(printf '%s\n' "$out" | sed 's|^\./||')
    personal=''
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      address=${hit##*:}
      domain=${address#*@}
      # A domain is reserved only when it ends with a reserved domain, and a
      # domain is written in either case.
      if [[ ! "${domain,,}" =~ $reserved_domain ]]; then
        personal+="${hit}"$'\n'
      fi
    done <<<"$out"
    if [[ -n "$personal" ]]; then
      report 'a personal address found' "${personal%$'\n'}"
    fi
    ;;
  1) ;;
  *)
    printf 'privacy-scan: the privacy scan failed (rg exit %s)\n%s\n' "$status" "$out" >&2
    exit 2
    ;;
esac

# The whole tree is searched for secret-like file names: the name of a
# file is private data wherever it lies, so the search has no depth limit.
# The git directory stays pruned at every depth. The well-known names that
# hold credentials are reported as well, and a link carries the name it
# was given, so a link with a secret-like name is reported too.
secret_files=$(find "$dir" \( -path '*/.git' -o -name '.git' \) -prune -o \
  \( -type f -o -type l \) \( -name '.DS_Store' -o -name '*secret*' -o -name '*.key' -o -name '*.pem' \
  -o -name '.env*' -o -name '*token*' -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' \
  -o -name 'id_ed25519' -o -name '.netrc' -o -name '_netrc' -o -name '.pgpass' -o -name '.htpasswd' \
  -o -name '.pypirc' -o -name '*.p12' -o -name '*.pfx' -o -name '*.jks' -o -name '*.keystore' \
  -o -name '*.ppk' -o -path '*/.aws/credentials' \) -print)
if [[ -n "$secret_files" ]]; then
  report 'a secret-like file name found' "$secret_files"
fi

if (( found > 0 )); then
  printf 'privacy-scan: the tree holds private data\n' >&2
  exit 1
fi

printf 'privacy-scan: ok\n'
