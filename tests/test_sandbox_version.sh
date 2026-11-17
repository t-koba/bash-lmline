#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: advisory version diagnostics must not gate execution or expose probe text.

tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-sandbox-version.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/config"
cat >"$tmp/msb" <<'MSB'
#!/usr/bin/env bash
if [[ ${1-} == --version ]]; then
  printf '%s\n' "$FAKE_MSB_VERSION"
  printf 'probe-stderr-sentinel\n' >&2
  exit "$FAKE_MSB_VERSION_STATUS"
fi
[[ ${1-} == --error ]] || exit 64
case ${2-} in
  inspect) exit 1 ;;
  create|copy) exit 0 ;;
  exec) printf 'ok echo\n' ;;
  *) exit 64 ;;
esac
MSB
chmod +x "$tmp/msb"
export LMLINE_CONFIG_DIR="$tmp/config" LMLINE_MICROSANDBOX_COMMAND="$tmp/msb"
printf 'echo\n' >"$tmp/commands"
export LMLINE_LOCAL_COMMANDS_FILE="$tmp/commands" LMLINE_SUGGESTED_COMMANDS_FILE="$tmp/commands"
printf 'warning=msb_version_below_0_7_12\nminimum_recommended=0.7.12\n' >"$tmp/warning"

check_version() {
  local label=$1 version=$2 status=$3 warn=$4 mode
  export FAKE_MSB_VERSION="$version" FAKE_MSB_VERSION_STATUS="$status"
  for mode in check setup; do
    local -a args=(sandbox "$mode")
    if [[ $mode == setup ]]; then
      args+=(--name version-test --image test-image --workspace none --root "$tmp")
    fi
    "$repo_dir/lmline/lmline" "${args[@]}" >"$tmp/out" 2>"$tmp/err" || fail "$label: $mode must remain successful"
    if [[ $warn == yes ]]; then
      cmp -s "$tmp/warning" "$tmp/err" || fail "$label: $mode fixed-label warning"
    else
      [[ ! -s "$tmp/err" ]] || fail "$label: $mode unexpected diagnostic"
    fi
    if [[ $mode == check ]]; then
      printf 'available=1\ncommand=%s\npath=%s\n' "$tmp/msb" "$tmp/msb" >"$tmp/expected"
      if (( status == 0 )) && [[ -n $version ]]; then
        printf 'version=%s\n' "$version" >>"$tmp/expected"
      else
        printf 'version=unknown\n' >>"$tmp/expected"
      fi
      cmp -s "$tmp/expected" "$tmp/out" || fail "$label: check fields changed"
    else
      grep -q '^sandbox_name=version-test$' "$tmp/out" || fail "$label: setup name"
      grep -q '^created=1$' "$tmp/out" || fail "$label: setup creation"
      grep -q '^workspace_mode=none$' "$tmp/out" || fail "$label: setup workspace"
      grep -q '^command_check:$' "$tmp/out" || fail "$label: setup command check"
      grep -q '^next_config:$' "$tmp/out" || fail "$label: setup next config"
      ! grep -q 'probe-.*sentinel' "$tmp/out" || fail "$label: setup leaked probe output"
    fi
  done
  ok "sandbox version $label (check and setup)"
}

check_version old 'msb 0.7.10 probe-stdout-sentinel' 0 yes
check_version minimum 'msb 0.7.12' 0 no
check_version unparseable 'msb unknown probe-stdout-sentinel' 0 no
check_version failed 'msb 0.7.10 probe-stdout-sentinel' 1 no
# Numeric comparison, token boundaries, and multiline output without overflow.
check_version minor 'msb 0.6.999' 0 yes
check_version patch 'msb 0.7.11' 0 yes
check_version newer 'msb 0.8.0' 0 no
check_version major 'msb 1.0.0' 0 no
check_version large 'msb 0.7.999999999999999999999999' 0 no
check_version zeroes 'msb 00.007.010' 0 yes
check_version decorated 'msb v0.7.10 0.7.10-rc1 0.7.10.1' 0 no
check_version multiline $'msb\n0.7.10\tprobe-stdout-sentinel' 0 yes
check_version empty '' 0 no
