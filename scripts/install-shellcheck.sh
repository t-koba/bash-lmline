#!/bin/sh
# Resolve the ShellCheck release pinned in pinned-downloads.txt and print its
# temporary binary directory to stdout (diagnostics go to stderr).
# Prefers /pinned/sha256/<digest>/<asset> when readable (sandbox), otherwise
# downloads the same manifest URL (GitHub CI). The digest is verified in both
# cases before extraction; the binary version must match the URL tag.
set -eu

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd) || exit 1
MANIFEST="${SCRIPT_DIR}/../pinned-downloads.txt"

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
MATCH_FILENAME=
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
    MATCH_FILENAME=$filename
    MATCH_COUNT=$((MATCH_COUNT + 1))
  fi
done < "$MANIFEST"

if [ "$MATCH_COUNT" -ne 1 ]; then
  printf 'install-shellcheck: expected one pin for %s, found %s\n' "$PLATFORM" "$MATCH_COUNT" >&2
  exit 1
fi

for command_name in tar mktemp awk; do
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

BIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shellcheck-bin.XXXXXX") || exit 1
trap 'rm -rf "$BIN_DIR"' 0
ARCHIVE="${BIN_DIR}/shellcheck.tar.xz"
CACHED="/pinned/sha256/${MATCH_SHA}/${MATCH_FILENAME}"
if [ -r "$CACHED" ]; then
  if ! cp "$CACHED" "$ARCHIVE"; then
    printf 'install-shellcheck: cannot copy cached archive\n' >&2
    exit 1
  fi
else
  if ! command -v curl >/dev/null 2>&1; then
    printf 'install-shellcheck: cached archive missing and curl is not installed\n' >&2
    exit 1
  fi
  if ! curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 "$MATCH_URL" -o "$ARCHIVE"; then
    printf 'install-shellcheck: download failed\n' >&2
    exit 1
  fi
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
if ! tar -xf "$ARCHIVE" -C "$BIN_DIR"; then
  printf 'install-shellcheck: archive extraction failed\n' >&2
  exit 1
fi
BIN_SRC="${BIN_DIR}/shellcheck-v${MATCH_VERSION}/shellcheck"
if [ ! -f "$BIN_SRC" ]; then
  printf 'install-shellcheck: binary missing after extraction\n' >&2
  exit 1
fi
cp "$BIN_SRC" "${BIN_DIR}/shellcheck" || exit 1
chmod +x "${BIN_DIR}/shellcheck" || exit 1
rm -rf "$ARCHIVE" "${BIN_DIR}/shellcheck-v${MATCH_VERSION}" || exit 1
VERSION_OUTPUT=$("${BIN_DIR}/shellcheck" --version) || exit 1
ACTUAL_VERSION=$(printf '%s\n' "$VERSION_OUTPUT" | awk '$1 == "version:" { print $2; exit }')
if [ "$ACTUAL_VERSION" != "$MATCH_VERSION" ]; then
  printf 'install-shellcheck: expected version %s, found %s\n' "$MATCH_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi

trap - 0
printf '%s\n' "$BIN_DIR"
printf 'install-shellcheck: installed ShellCheck %s for %s\n' "$MATCH_VERSION" "$PLATFORM" >&2
