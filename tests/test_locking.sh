#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: concurrent writers and stale locks cannot corrupt config/model state or bypass fail-closed locking.

cfg_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-lock-test.XXXXXX")
trap 'rm -rf "$cfg_tmp"' EXIT
cfg="$cfg_tmp/config"

# Concurrent config writers must not lose each other's updates. The names
# are catalogued settings, because the setter refuses a name the catalog
# does not know.
names=(LMLINE_SPINNER LMLINE_PROGRESS LMLINE_STREAM LMLINE_STORE LMLINE_STORE_FALLBACK \
  LMLINE_WEB_SEARCH LMLINE_ASYNC_NOTIFY LMLINE_INCLUDE_SHELL_CONTEXT LMLINE_INCLUDE_CWD_CONTEXT \
  LMLINE_INCLUDE_GIT_CONTEXT)
n=${#names[@]}
pids=()
for i in $(seq 1 "$n"); do
  LMLINE_CONFIG_DIR="$cfg" "$repo_dir/lmline/lmline" config set "${names[$((i - 1))]}" "value$i" \
    2>"$cfg_tmp/parallel-$i.err" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "parallel config set exited non-zero"
done
parallel_lock_warning=0
for i in $(seq 1 "$n"); do
  err="$cfg_tmp/parallel-$i.err"
  if grep -q 'not owned by this process' "$err"; then
    parallel_lock_warning=1
    holder=$(sed -n 's/.*(holder \([^)]*\));.*/\1/p' "$err" | head -n 1)
    phase=$(sed -n 's/.*release phase \([^;]*\);.*/\1/p' "$err" | head -n 1)
    [[ -n $phase ]] || phase=unknown
    relation=outside-batch
    if [[ $holder == "${pids[$((i - 1))]}" ]]; then
      relation=emitting-writer
    else
      for j in $(seq 1 "$n"); do
        if [[ $holder == "${pids[$((j - 1))]}" ]]; then
          relation="writer-$j"
          break
        fi
      done
    fi
    # Show synthetic writer indexes and a fixed release phase, never paths or PIDs.
    printf 'lock warning: writer=%s recorded-holder=%s release-phase=%s\n' "$i" "$relation" "$phase" >&2
  fi
done
for i in $(seq 1 "$n"); do
  grep -qxF "export ${names[$((i - 1))]}='value$i'" "$cfg/settings.bash" \
    || fail "parallel config set lost ${names[$((i - 1))]}"
done
((parallel_lock_warning == 0)) || fail "parallel config writer released a foreign lock"

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

# Dead-owner and ownerless locks must fail closed, including old directories.
for owner in 999999999 ''; do
  mkdir -p "$cfg/.lmline.lock"
  printf '%s\n' "$owner" >"$cfg/.lmline.lock/pid"
  touch -t 200001010000 "$cfg/.lmline.lock"
  if LMLINE_CONFIG_DIR="$cfg" LMLINE_LOCK_TIMEOUT=1 "$repo_dir/lmline/lmline" \
    config set LMLINE_SPINNER no 2>"$cfg_tmp/lock.err"; then
    fail "stale lock was reclaimed automatically"
  fi
  [[ -d "$cfg/.lmline.lock" ]] || fail "stale lock was deleted"
  [[ "$(cat "$cfg/.lmline.lock/pid")" == "$owner" ]] || fail "owner changed"
  rm -rf "$cfg/.lmline.lock"
done
LMLINE_CONFIG_DIR="$cfg" "$repo_dir/lmline/lmline" config set LMLINE_SPINNER ok \
  || fail "write after manual recovery failed"

# A lock held by a live process must block the writer until timeout.
mkdir -p "$cfg/.lmline.lock"
printf '%s\n' "$$" >"$cfg/.lmline.lock/pid"
if LMLINE_CONFIG_DIR="$cfg" LMLINE_LOCK_TIMEOUT=1 "$repo_dir/lmline/lmline" \
  config set LMLINE_PROGRESS no 2>"$cfg_tmp/lock.err"; then
  fail "live lock was not respected"
fi
grep -q 'locked by another lmline process' "$cfg_tmp/lock.err" || fail "lock timeout message"
rm -rf "$cfg/.lmline.lock"

# A non-owner must not delete another process's lock.
# shellcheck source=lmline/config.bash
source "$repo_dir/lmline/config.bash"
steal_lock="$cfg_tmp/steal.lock"
rm -rf "$steal_lock"
__lmline_lock_acquire "$steal_lock" 5 || fail "lock acquisition failed"
[[ "$(cat "$steal_lock/pid")" == "$BASHPID" ]] || fail "thief pid was not recorded"
bash -c 'source "$1/lmline/config.bash"; __lmline_lock_release "$2"' _ "$repo_dir" "$steal_lock" \
  2>"$cfg_tmp/steal.err" || fail "stale release exited non-zero"
[[ -d "$steal_lock" ]] || fail "stale release deleted the thief's lock"
grep -q 'not owned' "$cfg_tmp/steal.err" || fail "stale release did not warn"
__lmline_lock_release "$steal_lock" || fail "owned release failed"
[[ ! -e "$steal_lock" ]] || fail "owned release did not remove the lock"

# A subshell shares $$ with its parent; it must not release the parent's lock.
subshell_lock="$cfg_tmp/subshell.lock"
__lmline_lock_acquire "$subshell_lock" 5 || fail "subshell lock acquisition failed"
[[ "$(cat "$subshell_lock/pid")" == "$BASHPID" ]] || fail "lock did not record the current shell process"
(__lmline_lock_release "$subshell_lock") 2>"$cfg_tmp/subshell.err" || fail "subshell release exited non-zero"
[[ -d "$subshell_lock" ]] || fail "subshell release deleted the parent's lock"
grep -q 'not owned' "$cfg_tmp/subshell.err" || fail "subshell release did not warn"
__lmline_lock_release "$subshell_lock" || fail "parent release failed"
[[ ! -e "$subshell_lock" ]] || fail "parent release did not remove the lock"

# LMLINE_NO_LOCK=1 must bypass locking entirely.
mkdir -p "$cfg/.lmline.lock"
printf '%s\n' "$$" >"$cfg/.lmline.lock/pid"
LMLINE_CONFIG_DIR="$cfg" LMLINE_NO_LOCK=1 "$repo_dir/lmline/lmline" config set LMLINE_PROGRESS ok \
  || fail "LMLINE_NO_LOCK did not bypass the lock"
rm -rf "$cfg/.lmline.lock"

ok "config locking"
