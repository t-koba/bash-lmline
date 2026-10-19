#!/bin/sh
# Install the ShellCheck release pinned in pinned-downloads.txt for CI.
# The manifest's URL supplies the version; its digest is checked before use.
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
MANIFEST="${SCRIPT_DIR}/../pinned-downloads.txt"

if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "$RUNNER_TEMP" ]; then
  printf 'install-shellcheck: RUNNER_TEMP must name an existing directory\n' >&2
  exit 1
fi
if [ -z "${GITHUB_ENV:-}" ]; then
  printf 'install-shellcheck: GITHUB_ENV is not set\n' >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  printf 'install-shellcheck: pin manifest not found\n' >&2
  exit 1
fi

OS=$(uname -s) || exit 1
ARCH=$(uname -m) || exit 1
case "${OS}/${ARCH}" in
  Linux/x86_64) PLATFORM=linux.x86_64 ;;
  Darwin/arm64|Darwin/aarch64) PLATFORM=darwin.aarch64 ;;
  Darwin/x86_64) PLATFORM=darwin.x86_64 ;;
  *)
    printf 'install-shellcheck: unsupported OS/arch: %s/%s\n' "$OS" "$ARCH" >&2
    exit 1
    ;;
esac

COMMON_VERSION=
MATCH_VERSION=
MATCH_SHA=
MATCH_URL=
MATCH_COUNT=0
line=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  set -f
  # shellcheck disable=SC2086
  set -- $line
  set +f
  if [ "$#" -ne 2 ]; then
    printf 'install-shellcheck: malformed pin line\n' >&2
    exit 1
  fi
  sha=$1
  url=$2
  if [ "${#sha}" -ne 64 ]; then
    printf 'install-shellcheck: malformed SHA-256 in pin manifest\n' >&2
    exit 1
  fi
  case "$sha" in
    *[!0-9a-f]*)
      printf 'install-shellcheck: malformed SHA-256 in pin manifest\n' >&2
      exit 1
      ;;
  esac
  case "$url" in
    https://github.com/koalaman/shellcheck/releases/download/v*/shellcheck-v*.tar.xz) ;;
    *)
      printf 'install-shellcheck: pin URL is not an official HTTPS ShellCheck release asset\n' >&2
      exit 1
      ;;
  esac
  release_path=${url#https://github.com/koalaman/shellcheck/releases/download/}
  tag=${release_path%%/*}
  filename=${release_path#*/}
  case "$tag" in
    v*) version=${tag#v} ;;
    *)
      printf 'install-shellcheck: malformed release tag in pin manifest\n' >&2
      exit 1
      ;;
  esac
  case "$version" in
    ''|*[!0-9.]*)
      printf 'install-shellcheck: malformed release version in pin manifest\n' >&2
      exit 1
      ;;
  esac
  case "$filename" in
    "shellcheck-v${version}.linux.x86_64.tar.xz"|\
    "shellcheck-v${version}.darwin.aarch64.tar.xz"|\
    "shellcheck-v${version}.darwin.x86_64.tar.xz") ;;
    *)
      printf 'install-shellcheck: asset name does not match its release tag\n' >&2
      exit 1
      ;;
  esac
  if [ -z "$COMMON_VERSION" ]; then
    COMMON_VERSION=$version
  elif [ "$version" != "$COMMON_VERSION" ]; then
    printf 'install-shellcheck: pin manifest mixes release versions\n' >&2
    exit 1
  fi
  if [ "$filename" = "shellcheck-v${version}.${PLATFORM}.tar.xz" ]; then
    MATCH_VERSION=$version
    MATCH_SHA=$sha
    MATCH_URL=$url
    MATCH_COUNT=$((MATCH_COUNT + 1))
  fi
done < "$MANIFEST"

if [ "$MATCH_COUNT" -ne 1 ]; then
  printf 'install-shellcheck: expected one pin for %s, found %s\n' "$PLATFORM" "$MATCH_COUNT" >&2
  exit 1
fi

for command_name in curl tar mktemp awk sed; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'install-shellcheck: required command missing: %s\n' "$command_name" >&2
    exit 1
  fi
done
if [ "$OS" = Darwin ]; then
  if ! command -v shasum >/dev/null 2>&1; then
    printf 'install-shellcheck: shasum is required\n' >&2
    exit 1
  fi
else
  if ! command -v sha256sum >/dev/null 2>&1; then
    printf 'install-shellcheck: sha256sum is required\n' >&2
    exit 1
  fi
fi

WORK_DIR=$(mktemp -d "${RUNNER_TEMP}/shellcheck.XXXXXX") || exit 1
trap 'rm -rf "$WORK_DIR"' 0
ARCHIVE="${WORK_DIR}/shellcheck.tar.xz"
if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 "$MATCH_URL" -o "$ARCHIVE"; then
  printf 'install-shellcheck: download failed\n' >&2
  exit 1
fi

if [ "$OS" = Darwin ]; then
  ACTUAL_SHA=$(shasum -a 256 "$ARCHIVE" | awk 'NR == 1 { print $1 }') || exit 1
else
  ACTUAL_SHA=$(sha256sum "$ARCHIVE" | awk 'NR == 1 { print $1 }') || exit 1
fi
if [ "$ACTUAL_SHA" != "$MATCH_SHA" ]; then
  printf 'install-shellcheck: SHA-256 mismatch for %s\n' "$PLATFORM" >&2
  exit 1
fi
if ! tar -xf "$ARCHIVE" -C "$WORK_DIR"; then
  printf 'install-shellcheck: archive extraction failed\n' >&2
  exit 1
fi
BIN_SRC="${WORK_DIR}/shellcheck-v${MATCH_VERSION}/shellcheck"
if [ ! -f "$BIN_SRC" ]; then
  printf 'install-shellcheck: binary missing after extraction\n' >&2
  exit 1
fi
chmod +x "$BIN_SRC" || exit 1
VERSION_OUTPUT=$("$BIN_SRC" --version) || exit 1
ACTUAL_VERSION=$(printf '%s\n' "$VERSION_OUTPUT" | awk '$1 == "version:" { print $2; exit }')
if [ "$ACTUAL_VERSION" != "$MATCH_VERSION" ]; then
  printf 'install-shellcheck: expected version %s, found %s\n' "$MATCH_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

BIN_DIR="${RUNNER_TEMP}/shellcheck-bin"
mkdir -p "$BIN_DIR" || exit 1
cp "$BIN_SRC" "${BIN_DIR}/shellcheck" || exit 1
chmod +x "${BIN_DIR}/shellcheck" || exit 1
if ! printf 'SHELLCHECK_BIN_DIR=%s\n' "$BIN_DIR" >> "$GITHUB_ENV"; then
  printf 'install-shellcheck: cannot write GITHUB_ENV\n' >&2
  exit 1
fi
printf 'install-shellcheck: installed ShellCheck %s for %s\n' "$MATCH_VERSION" "$PLATFORM"
