#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-lock-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
cfg="$cfg_tmp/config"

# Concurrent config writers must not lose each other's updates.
n=10
pids=()
for i in $(seq 1 "$n"); do
  LMLINE_CONFIG_DIR="$cfg" "$repo_dir/lmline/lmline" config set "LMLINE_TEST_KEY_$i" "value$i" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "parallel config set exited non-zero"
done
for i in $(seq 1 "$n"); do
  grep -qxF "export LMLINE_TEST_KEY_$i='value$i'" "$cfg/settings.bash" \
    || fail "parallel config set lost LMLINE_TEST_KEY_$i"
done

# Concurrent model adds must not lose rows in models.tsv.
LMLINE_CONFIG_DIR="$cfg" "$repo_dir/lmline/lmline" endpoint add local http://127.0.0.1:1234/v1 >/dev/null
pids=()
for i in $(seq 1 "$n"); do
  LMLINE_CONFIG_DIR="$cfg" "$repo_dir/lmline/lmline" model add local "model-$i" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "parallel model add exited non-zero"
done
for i in $(seq 1 "$n"); do
  grep -q "^local	model-$i	" "$cfg/models.tsv" || fail "parallel model add lost model-$i"
done

# A lock left behind by a dead process must be stolen, not block forever.
mkdir -p "$cfg/.lmline.lock"
printf '%s\n' 999999999 >"$cfg/.lmline.lock/pid"
LMLINE_CONFIG_DIR="$cfg" "$repo_dir/lmline/lmline" config set LMLINE_TEST_STALE ok \
  || fail "stale lock was not stolen"
grep -qxF "export LMLINE_TEST_STALE='ok'" "$cfg/settings.bash" || fail "write after stale steal"
[[ ! -d "$cfg/.lmline.lock" ]] || fail "lock released after steal"

# A lock held by a live process must block the writer until timeout.
mkdir -p "$cfg/.lmline.lock"
printf '%s\n' "$$" >"$cfg/.lmline.lock/pid"
if LMLINE_CONFIG_DIR="$cfg" LMLINE_LOCK_TIMEOUT=1 "$repo_dir/lmline/lmline" \
  config set LMLINE_TEST_BLOCKED no 2>"$cfg_tmp/lock.err"; then
  fail "live lock was not respected"
fi
grep -q 'locked by another lmline process' "$cfg_tmp/lock.err" || fail "lock timeout message"
rm -rf "$cfg/.lmline.lock"

# LMLINE_NO_LOCK=1 must bypass locking entirely.
mkdir -p "$cfg/.lmline.lock"
printf '%s\n' "$$" >"$cfg/.lmline.lock/pid"
LMLINE_CONFIG_DIR="$cfg" LMLINE_NO_LOCK=1 "$repo_dir/lmline/lmline" config set LMLINE_TEST_NOLOCK ok \
  || fail "LMLINE_NO_LOCK did not bypass the lock"
rm -rf "$cfg/.lmline.lock"

ok "config locking"
