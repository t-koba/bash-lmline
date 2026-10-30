#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
export LC_ALL=C.UTF-8 LANG=C.UTF-8
unset SHELLCHECK_OPTS GHCRTS
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
poc=$repo/tools/shellcheck-api-poc
results=$poc/_run/results
source_commit=aac0823e6b58f8a499e856e93738082691cbf212
mkdir -p "$results"
cd "$poc"

# systemd cgroups cap total charged memory (not just RSS), disallow swap,
# and kill the entire command group on timeout. No host toolchain install.
# Service LimitFSIZE bounds file writes by phase; command output is capped at
# 64 MiB/file and retained logs/artifacts at 8 MiB/file after a successful run.
limited() {
  local label=$1 seconds=$2 extension=$3 status=0 arg file_limit=8M
  case "$label" in
    update) file_limit=1G ;; # Hackage's package index exceeds the 8 MiB log cap.
    compile|freeze|plan) file_limit=256M ;;
  esac
  shift 3
  {
    printf '%s: memory.max=4G memory.swap.max=0 file_limit=%s output_cap=64M runtime=%ss command=' "$label" "$file_limit" "$seconds"
    for arg in "$@"; do printf '%q ' "${arg//"$repo"/<repo>}"; done
    printf '\n'
  } >> "$results/commands.txt"
  (
    ulimit -f 131072 # 512-byte blocks: 131072 * 512 = 64 MiB per captured output file.
    exec sudo -n systemd-run --quiet --wait --pipe --collect \
      --unit="shellcheck-poc-${label}-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}" \
      --uid="$(id -u)" --gid="$(id -g)" \
      --working-directory="$PWD" \
      --setenv="PATH=$PATH" --setenv="HOME=$HOME" \
      --setenv=LC_ALL=C.UTF-8 --setenv=LANG=C.UTF-8 --setenv=SHELLCHECK_OPTS= --setenv=GHCRTS= \
      --property=MemoryMax=4G --property=MemorySwapMax=0 \
      --property="RuntimeMaxSec=$((seconds + 10))" \
      --property=KillMode=control-group --property=TimeoutStopSec=5 \
      --property="LimitFSIZE=$file_limit" \
      /usr/bin/time -f 'elapsed_s=%e\npeak_rss_kib=%M\nexit_status=%x' \
      -o "$results/$label.time" \
      timeout --signal=TERM --kill-after=5s "${seconds}s" "$@"
  ) > "$results/$label.$extension" 2> "$results/$label.stderr" || status=$?
  printf '%s\n' "$status" > "$results/$label.status"
  return "$status"
}

archive() {
  local file=$1 name=$2
  test "$(stat -c %s "$file")" -le 8388608
  cp "$file" "$results/$name"
  (cd "$results" && sha256sum "$name") >> "$results/identities.sha256"
}

check_lock() {
  cmp cabal.project.freeze "$results/cabal.project.freeze"
  (cd "$results" && sha256sum --check identities.sha256)
}

case "${1:-}" in
  resolve)
    test "$(ghc --numeric-version)" = 9.6.6
    test "$(cabal --numeric-version)" = 3.10.3.0
    {
      ghc --version
      cabal --version
      printf 'ShellCheck source v0.11.0: %s\n' "$source_commit"
      printf 'Hackage index-state: 2026-01-01T00:00:00Z\nsolver: modular (cabal-install 3.10.3.0)\n'
      printf 'API flags: -O1 -threaded -rtsopts -with-rtsopts=-N1; jobs=1\n'
    } > "$results/versions.txt"
    archive run.sh run.sh
    archive Main.hs Main.hs
    archive compare.py compare.py
    archive cabal.project cabal.project
    archive shellcheck-api-poc.cabal shellcheck-api-poc.cabal
    archive "$repo/.shellcheckrc" shellcheckrc
    archive "$repo/pinned-downloads.txt" pinned-downloads.txt
    archive "$repo/tests/test_endpoint_display.sh" test_endpoint_display.sh
    # Existing installer verifies the existing manifest digest AND CLI version.
    cli_dir=$(timeout --kill-after=5s 90s bash "$repo/scripts/install-shellcheck.sh" 2> "$results/installer.stderr")
    mkdir -p _run/bin
    cp "$cli_dir/shellcheck" _run/bin/shellcheck
    rm -rf -- "$cli_dir"
    _run/bin/shellcheck --version >> "$results/versions.txt"
    grep -qx 'version: 0.11.0' <(_run/bin/shellcheck --version)
    (cd _run/bin && sha256sum shellcheck) > "$results/cli.sha256"
    # No moving branch/tag resolution: fetch the exact reviewed tag commit.
    git init -q _run/ShellCheck
    git -C _run/ShellCheck remote add origin https://github.com/koalaman/shellcheck.git
    timeout --kill-after=5s 90s git -C _run/ShellCheck fetch -q --depth=1 origin tag v0.11.0
    git -C _run/ShellCheck checkout -q --detach v0.11.0
    test "$(git -C _run/ShellCheck rev-parse HEAD)" = "$source_commit"
    # Resolve/freeze first; dry-run elaborates and archives the actual plan
    # before any compilation. All subsequent operations consume this freeze.
    limited update 90 stdout cabal update
    limited freeze 90 stdout cabal freeze --project-file=cabal.project
    archive cabal.project.freeze cabal.project.freeze
    limited plan 60 stdout cabal build exe:shellcheck-api-poc --dry-run --offline --jobs=1
    archive dist-newstyle/cache/plan.json plan.before-build.json
    ;;
  build)
    check_lock
    limited compile 900 stdout cabal build exe:shellcheck-api-poc --jobs=1
    check_lock
    archive dist-newstyle/cache/plan.json plan.after-build.json
    api_bin=$(cabal list-bin exe:shellcheck-api-poc --offline)
    cp "$api_bin" _run/bin/shellcheck-api-poc
    (cd _run/bin && sha256sum shellcheck-api-poc) > "$results/api.sha256"
    ;;
  measure)
    check_lock
    (cd _run/bin && sha256sum --check "$results/cli.sha256" "$results/api.sha256")
    cd "$repo"
    inputs=(tests/test_endpoint_display.sh)
    # Sequential, one process per implementation, identical source allowlist.
    limited cli 180 json "$poc/_run/bin/shellcheck" -s bash --rcfile=.shellcheckrc --format=json "${inputs[@]}" || true
    limited api 180 json "$poc/_run/bin/shellcheck-api-poc" +RTS -N1 -M3G -RTS || true
    python3 "$poc/compare.py" "$results"
    ;;
  *) printf 'usage: run.sh resolve|build|measure\n' >&2; exit 2 ;;
esac
