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
first_missing_setting=0
for i in $(seq 1 "$n"); do
  if ! grep -qxF "export ${names[$((i - 1))]}='value$i'" "$cfg/settings.bash"; then
    first_missing_setting=$i
    break
  fi
done
if ((parallel_lock_warning || first_missing_setting)); then
  # Re-run only a failed batch under a private DEBUG hook and command wrappers.
  # The passing path stays uninstrumented so diagnostics cannot mask its interleaving.
  diag_cfg=$cfg_tmp/diagnostic-config
  trace_bin=$cfg_tmp/trace-bin
  trace_file=$(mktemp "$cfg_tmp/lock-events.XXXXXX")
  trace_helper=$(mktemp "$cfg_tmp/trace-env.XXXXXX")
  mkdir "$trace_bin"
  # mktemp keeps the raw trace and helper mode 600. Do not dump either.
  cat >"$trace_helper" <<'EOF'
# The replay starts privileged before sourcing this helper or the CLI. Keep
# the hook out of BASH_ENV and child utility wrappers; do not rewrite production.
set -T
__lmline_test_lock_debug() {
  local status=$1 cmd=$2 func=$3 caller_pid=$4 operation=
  # DEBUG runs before commands. The next hook observes the printf's result;
  # key pending state by BASHPID so inherited subshell hooks cannot consume it.
  if [[ ${__lmline_test_owner_pending-} == "$caller_pid" ]]; then
    printf '%s owner-write %s %s\n' "$LMLINE_TEST_LOCK_WRITER" "$status" "$caller_pid" >>"$LMLINE_TEST_LOCK_TRACE"
    unset __lmline_test_owner_pending
  fi
  if [[ $func == __lmline_lock_acquire && $cmd == printf* && $cmd == *BASHPID* && $cmd == *'/pid'* ]]; then
    __lmline_test_owner_pending=$caller_pid
    operation=owner-write-start
  elif [[ $func == __lmline_lock_release && $cmd == local* ]]; then
    operation=release-start
  fi
  # Start events carry the incoming status, not a result of the next command.
  if [[ -n $operation ]]; then
    printf '%s %s %s %s\n' "$LMLINE_TEST_LOCK_WRITER" "$operation" "$status" "$caller_pid" >>"$LMLINE_TEST_LOCK_TRACE"
  fi
  return 0
}
trap '__lmline_test_lock_debug "$?" "$BASH_COMMAND" "${FUNCNAME[0]-}" "$BASHPID"' DEBUG
EOF
  for utility in mkdir rm cat; do
    cat >"$trace_bin/$utility" <<'EOF'
#!/usr/bin/env bash
tool=${0##*/}
target=
for arg in "$@"; do target=$arg; done
operation=
owner_pid=
if [[ $tool == mkdir && $# == 1 && ${1-} == "${LMLINE_TEST_LOCK_PATH-}" ]]; then
  operation=acquire
elif [[ $tool == rm && $target == "${LMLINE_TEST_LOCK_PATH-}" ]]; then
  operation=remove
elif [[ $tool == cat && $# == 1 && ${1-} == "${LMLINE_TEST_LOCK_PATH-}/pid" ]]; then
  operation=owner-read
fi
# Keep raw process IDs only in this temporary trace; the parent maps them to
# fixed writer labels before printing any diagnostic output.
if [[ $operation == owner-read || $operation == remove ]]; then
  owner_pid=$(command -p cat "${LMLINE_TEST_LOCK_PATH-}/pid" 2>/dev/null) || owner_pid=
fi
command -p "$tool" "$@"
status=$?
if [[ -n $operation && -n ${LMLINE_TEST_LOCK_TRACE-} ]]; then
  printf '%s %s %s %s %s\n' "${LMLINE_TEST_LOCK_WRITER:-0}" "$operation" "$status" "$PPID" "$owner_pid" >>"$LMLINE_TEST_LOCK_TRACE"
fi
exit "$status"
EOF
    chmod +x "$trace_bin/$utility"
  done
  diag_pids=()
  for i in $(seq 1 "$n"); do
    PATH="$trace_bin:$PATH" LMLINE_TEST_LOCK_TRACE="$trace_file" LMLINE_TEST_LOCK_PATH="$diag_cfg/.lmline.lock" \
      LMLINE_TEST_LOCK_WRITER="$i" LMLINE_CONFIG_DIR="$diag_cfg" \
      command bash -p -c 'source "$1"; shift; source "$0" "$@"' \
        "$repo_dir/lmline/lmline" "$trace_helper" config set "${names[$((i - 1))]}" "value$i" 2>/dev/null &
    diag_pids+=($!)
  done
  for pid in "${diag_pids[@]}"; do wait "$pid" || true; done
  lock_writer_label() {
    local target=$1 index
    for index in "${!diag_pids[@]}"; do
      if [[ $target == "${diag_pids[$index]}" ]]; then
        printf 'writer-%s' "$((index + 1))"
        return 0
      fi
    done
    printf outside-batch
  }
  while read -r writer operation status caller_pid owner_pid; do
    [[ -n $writer ]] || continue
    caller_label=$(lock_writer_label "$caller_pid")
    if [[ $owner_pid =~ ^[0-9]+$ ]]; then
      owner_label=$(lock_writer_label "$owner_pid")
    else
      owner_label=none
    fi
    printf 'lock trace: writer=%s operation=%s status=%s caller=%s holder=%s\n' \
      "$writer" "$operation" "$status" "$caller_label" "$owner_label" >&2
  done <"$trace_file"
fi
((first_missing_setting == 0)) || fail "parallel config set lost ${names[$((first_missing_setting - 1))]}"
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
