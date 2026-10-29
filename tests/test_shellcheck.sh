#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: pinned ShellCheck covers every supported Bash source/test input with correct source resolution.

# Emit only bounded numeric telemetry; ShellCheck's own stdout/stderr remains
# attached so the original diagnostics are neither filtered nor delayed.
__lmline_shellcheck_proc_rss() {
  local pid=$1 key value unit rss=na peak=na
  if [[ -r "/proc/$pid/status" ]]; then
    while read -r key value unit; do
      case "$key" in
        VmRSS:) if [[ "$value" =~ ^[0-9]+$ ]]; then rss=$value; fi ;;
        VmHWM:) if [[ "$value" =~ ^[0-9]+$ ]]; then peak=$value; fi ;;
      esac
    done < "/proc/$pid/status"
  fi
  printf '%s %s\n' "$rss" "$peak"
}

__lmline_shellcheck_tree_rss() {
  local pid=$1 root root_peak child_total child_peak child_count child_pid child_rss child_hwm tree child_capped=0
  local -a child_pids=()
  read -r root root_peak < <(__lmline_shellcheck_proc_rss "$pid")
  child_total=na
  child_peak=na
  child_count=na
  if [[ -r "/proc/$pid/task/$pid/children" ]]; then
    child_total=0
    child_peak=0
    IFS=' ' read -r -n 256 -a child_pids < "/proc/$pid/task/$pid/children" || true
    child_count=${#child_pids[@]}
    if ((child_count > 16)); then
      child_count=16
      child_capped=1
    fi
    for child_pid in "${child_pids[@]:0:16}"; do
      if [[ ! "$child_pid" =~ ^[0-9]+$ ]]; then
        continue
      fi
      read -r child_rss child_hwm < <(__lmline_shellcheck_proc_rss "$child_pid")
      if [[ "$child_rss" =~ ^[0-9]+$ && "$child_total" =~ ^[0-9]+$ ]]; then
        child_total=$((child_total + child_rss))
      else
        child_total=na
      fi
      if [[ "$child_hwm" =~ ^[0-9]+$ && "$child_peak" =~ ^[0-9]+$ ]]; then
        child_peak=$((child_peak + child_hwm))
      else
        child_peak=na
      fi
    done
    if ((child_capped)); then
      child_count='16+'
      child_total=na
      child_peak=na
    fi
  fi
  if [[ "$root" =~ ^[0-9]+$ && "$child_total" =~ ^[0-9]+$ ]]; then
    tree=$((root + child_total))
  else
    tree=na
  fi
  printf '%s %s %s %s %s %s\n' "$root" "$child_total" "$child_count" "$tree" "$root_peak" "$child_peak"
}

__lmline_shellcheck_memory_kib() {
  local key value unit available=na total=na
  if [[ -r /proc/meminfo ]]; then
    while read -r key value unit; do
      case "$key" in
        MemAvailable:) if [[ "$value" =~ ^[0-9]+$ ]]; then available=$value; fi ;;
        MemTotal:) if [[ "$value" =~ ^[0-9]+$ ]]; then total=$value; fi ;;
      esac
    done < /proc/meminfo
  fi
  printf '%s %s\n' "$available" "$total"
}

__lmline_shellcheck_cgroup_memory() {
  local pid=$1 hierarchy controllers path cgroup_dir='' current=na limit=na peak=na oom=na oom_kill=na key value
  if [[ -r "/proc/$pid/cgroup" ]]; then
    while IFS=: read -r hierarchy controllers path; do
      if [[ "$hierarchy" == 0 && -z "$controllers" ]]; then
        path=${path#/}
        if [[ "$path" != *..* ]]; then
          cgroup_dir=/sys/fs/cgroup
          [[ -z "$path" ]] || cgroup_dir="$cgroup_dir/$path"
        fi
        break
      fi
    done < "/proc/$pid/cgroup"
  fi
  if [[ -n "$cgroup_dir" && -r "$cgroup_dir/memory.current" && -r "$cgroup_dir/memory.max" ]]; then
    read -r current < "$cgroup_dir/memory.current" || current=na
    read -r limit < "$cgroup_dir/memory.max" || limit=na
    if [[ -r "$cgroup_dir/memory.peak" ]]; then
      read -r peak < "$cgroup_dir/memory.peak" || peak=na
    fi
    if [[ -r "$cgroup_dir/memory.events" ]]; then
      while read -r key value; do
        case "$key" in
          oom) oom=$value ;;
          oom_kill) oom_kill=$value ;;
        esac
      done < "$cgroup_dir/memory.events"
    fi
  fi
  [[ "$current" =~ ^[0-9]+$ ]] || current=na
  [[ "$limit" =~ ^[0-9]+$ || "$limit" == max ]] || limit=na
  [[ "$peak" =~ ^[0-9]+$ ]] || peak=na
  [[ "$oom" =~ ^[0-9]+$ ]] || oom=na
  [[ "$oom_kill" =~ ^[0-9]+$ ]] || oom_kill=na
  printf '%s %s %s %s %s\n' "$current" "$limit" "$peak" "$oom" "$oom_kill"
}

__lmline_shellcheck_write_record() {
  local diagnostics_file=$1 line=$2
  printf 'shellcheck-resource %s\n' "$line"
  if [[ -n "$diagnostics_file" ]]; then
    printf '%s\n' "$line" >> "$diagnostics_file" 2>/dev/null || true
  fi
}

__lmline_shellcheck_record_sample() {
  local label=$1 phase=$2 pid=$3 elapsed=$4 wait_status=$5 exit_status=$6 signal_candidate=$7 diagnostics_file=$8
  local rss child_rss child_count tree process_peak child_peak available total current limit cgroup_peak oom oom_kill
  read -r rss child_rss child_count tree process_peak child_peak < <(__lmline_shellcheck_tree_rss "$pid")
  read -r available total < <(__lmline_shellcheck_memory_kib)
  read -r current limit cgroup_peak oom oom_kill < <(__lmline_shellcheck_cgroup_memory "$pid")
  __lmline_shellcheck_write_record "$diagnostics_file" \
    "label=$label phase=$phase elapsed_s=$elapsed process_rss_kib=$rss process_peak_rss_kib=$process_peak child_rss_kib=$child_rss child_peak_rss_kib=$child_peak child_count=$child_count rss_tree_kib=$tree available_ram_kib=$available total_ram_kib=$total cgroup_current_bytes=$current cgroup_limit_bytes=$limit cgroup_peak_bytes=$cgroup_peak cgroup_oom=$oom cgroup_oom_kill=$oom_kill wait_status=$wait_status exit_status=$exit_status signal_candidate=$signal_candidate"
}

__lmline_shellcheck_process_running() {
  local pid=$1 stat remainder state
  if [[ -r "/proc/$pid/stat" ]]; then
    if ! IFS= read -r stat < "/proc/$pid/stat"; then
      return 1
    fi
    remainder=${stat##*) }
    state=${remainder%% *}
    [[ -n "$state" && "$state" != Z && "$state" != X ]]
  else
    kill -0 "$pid" 2>/dev/null
  fi
}

__lmline_shellcheck_run_monitored() {
  local label=$1 interval=$2 sample_cap=$3 diagnostics_file=$4
  shift 4
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ || ! "$sample_cap" =~ ^[1-9][0-9]*$ || $# -eq 0 ]]; then
    return 2
  fi
  local pid started elapsed next_sample sample_count=0 cap_logged=0 status exit_status signal_candidate
  "$@" &
  pid=$!
  started=$SECONDS
  next_sample=$interval
  __lmline_shellcheck_record_sample "$label" start "$pid" 0 running na na "$diagnostics_file"
  while __lmline_shellcheck_process_running "$pid"; do
    sleep 1
    elapsed=$((SECONDS - started))
    if ((elapsed >= next_sample)); then
      if ((sample_count < sample_cap)); then
        sample_count=$((sample_count + 1))
        __lmline_shellcheck_record_sample "$label" progress "$pid" "$elapsed" running na na "$diagnostics_file"
      elif ((cap_logged == 0)); then
        __lmline_shellcheck_write_record "$diagnostics_file" "label=$label phase=sample_cap elapsed_s=$elapsed sample_cap=$sample_cap"
        cap_logged=1
      fi
      next_sample=$((next_sample + interval))
    fi
  done
  if wait "$pid"; then
    status=0
  else
    status=$?
  fi
  elapsed=$((SECONDS - started))
  if ((status >= 128)); then
    exit_status=na
    signal_candidate=$((status - 128))
  else
    exit_status=$status
    signal_candidate=na
  fi
  # Bash's wait status cannot distinguish a signal from an explicit 128+N exit.
  __lmline_shellcheck_record_sample "$label" final "$pid" "$elapsed" "$status" "$exit_status" "$signal_candidate" "$diagnostics_file"
  return "$status"
}

__lmline_shellcheck_monitor_self_test() {
  local test_dir output_file diagnostics_file release_file status progress_count attempt monitor_pid saw_cap=0
  test_dir=$(mktemp -d) || fail "could not create ShellCheck monitor test directory"
  output_file="$test_dir/output"
  diagnostics_file="$test_dir/diagnostics"
  release_file="$test_dir/release"
  : > "$output_file"
  : > "$diagnostics_file"

  __lmline_shellcheck_run_monitored monitor-test 1 1 '' bash -c 'while [[ ! -e "$1" ]]; do sleep 1; done; exit 7' _ "$release_file" > "$output_file" 2>&1 &
  monitor_pid=$!
  attempt=0
  while ((attempt < 30)); do
    if grep -q 'label=monitor-test phase=sample_cap ' "$output_file"; then
      saw_cap=1
      break
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  : > "$release_file"
  if ((saw_cap)); then
    if wait "$monitor_pid"; then
      status=0
    else
      status=$?
    fi
  else
    kill -TERM "$monitor_pid" 2>/dev/null || true
    if wait "$monitor_pid"; then
      status=0
    else
      status=$?
    fi
    rm -rf "$test_dir"
    fail "ShellCheck monitor did not reach a bounded sample under test"
  fi
  progress_count=$(grep -c 'label=monitor-test phase=progress ' "$output_file" || true)
  if [[ "$status" != 7 || "$progress_count" != 1 ]] || ! grep -q 'label=monitor-test phase=final .*wait_status=7 exit_status=7 signal_candidate=na' "$output_file"; then
    rm -rf "$test_dir"
    fail "ShellCheck monitor did not preserve bounded progress and child exit status"
  fi
  if [[ -r /proc/$$/status ]] && ! grep -Eq 'phase=progress .*process_rss_kib=[0-9]+ process_peak_rss_kib=[0-9]+ child_rss_kib=([0-9]+|na) child_peak_rss_kib=([0-9]+|na) child_count=([0-9]+|na) rss_tree_kib=([0-9]+|na)' "$output_file"; then
    rm -rf "$test_dir"
    fail "ShellCheck monitor did not sample bounded RSS metrics"
  fi

  if __lmline_shellcheck_run_monitored signal-test 1 1 '' bash -c 'kill -TERM "$$"' > "$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" != 143 ]] || ! grep -q 'label=signal-test phase=final .*wait_status=143 exit_status=na signal_candidate=15' "$output_file"; then
    rm -rf "$test_dir"
    fail "ShellCheck monitor did not retain child signal status"
  fi
  if __lmline_shellcheck_run_monitored artifact-test 10 1 "$diagnostics_file" bash -c 'exit 5' > "$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi
  if [[ "$status" != 5 ]] || ! grep -q 'label=artifact-test phase=final .*wait_status=5 exit_status=5 signal_candidate=na' "$diagnostics_file"; then
    rm -rf "$test_dir"
    fail "ShellCheck monitor did not retain its bounded diagnostic file"
  fi
  rm -rf "$test_dir"
  ok "shellcheck resource monitor"
}

# With no arguments runs the full ShellCheck batch (pinned via
# scripts/install-shellcheck.sh when LMLINE_REQUIRE_SHELLCHECK=1, otherwise
# an installed shellcheck or skip). --provision-only verifies the pinned
# platform asset without linting; --monitor-self-test exercises the bounded
# telemetry wrapper with controlled child exit and signal cases.
provision_only=0
monitor_self_test=0
if (($# > 1)); then
  printf 'usage: %s [--provision-only|--monitor-self-test]\n' "$0" >&2
  exit 2
elif (($# == 1)); then
  case "$1" in
    --provision-only) provision_only=1 ;;
    --monitor-self-test) monitor_self_test=1 ;;
    *)
      printf 'usage: %s [--provision-only|--monitor-self-test]\n' "$0" >&2
      exit 2
      ;;
  esac
fi
if ((monitor_self_test)); then
  __lmline_shellcheck_monitor_self_test
  exit 0
fi

# Resolve ShellCheck source hints consistently, including direct invocations from elsewhere.
cd -- "$repo_dir" || fail "could not enter repository root for ShellCheck"

if ((provision_only)); then
  pinned_bin_dir=$(sh "$repo_dir/scripts/install-shellcheck.sh") || fail "pinned ShellCheck setup failed"
  trap 'rm -rf "$pinned_bin_dir"' EXIT
  PATH="$pinned_bin_dir:$PATH"
  command -v shellcheck >/dev/null 2>&1 || fail "pinned shellcheck not found"
  shellcheck --version >/dev/null 2>&1 || fail "pinned shellcheck version check failed"
  ok "shellcheck provisioning"
  exit 0
fi

__lmline_shellcheck_monitor_self_test

# init.zsh is excluded: shellcheck does not support zsh; zsh -n covers it in
# test_syntax.sh. LMLINE_REQUIRE_SHELLCHECK=1 (set in CI)
# always uses the manifest pin via scripts/install-shellcheck.sh (which
# prefers /pinned and otherwise downloads the same URL); otherwise an
# installed shellcheck is used, or the test skips when none is installed.
if [[ "${LMLINE_REQUIRE_SHELLCHECK:-0}" == 1 ]]; then
  pinned_bin_dir=$(sh "$repo_dir/scripts/install-shellcheck.sh") || fail "pinned ShellCheck setup failed"
  trap 'rm -rf "$pinned_bin_dir"' EXIT
  PATH="$pinned_bin_dir:$PATH"
  command -v shellcheck >/dev/null 2>&1 || fail "pinned shellcheck not found"
else
  if ! command -v shellcheck >/dev/null 2>&1; then
    ok "shellcheck (skipped: not installed)"
    exit 0
  fi
fi

diagnostics_file=''
if [[ "${GITHUB_ACTIONS:-false}" == true && -n "${RUNNER_TEMP:-}" ]]; then
  diagnostics_file="$RUNNER_TEMP/lmline-shellcheck-diagnostics.log"
  : > "$diagnostics_file" 2>/dev/null || diagnostics_file=''
fi
# A 30-second interval caps resource output at 60 samples (30 minutes);
# the cap bounds telemetry only and never times out or changes ShellCheck.
__lmline_shellcheck_run_monitored shellcheck 30 60 "$diagnostics_file" \
  shellcheck -s bash \
  "$repo_dir/lmline/lmline" \
  "$repo_dir/lmline/engine" \
  "$repo_dir/lmline/validate" \
  "$repo_dir"/lmline/*.bash \
  "$repo_dir/lmline/completions/lmline.bash" \
  "$repo_dir/install.sh" \
  "$repo_dir/scripts/install-shellcheck.sh" \
  "$repo_dir/scripts/check-commit-subjects.sh" \
  "$repo_dir/scripts/privacy-scan.sh" \
  "$repo_dir/scripts/publish-check.sh" \
  "$repo_dir"/tests/*.sh \
  || fail "shellcheck findings"
ok "shellcheck"
