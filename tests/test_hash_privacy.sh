#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: direct startup/reload and helper hash children inherit raw Bash bodies.
hash_tmp=$(mktemp -d "${TMPDIR:-/tmp}/lmline-hash-privacy.XXXXXX")
trap 'rm -rf "$hash_tmp"' EXIT
export HASH_TEST_DIR=$hash_tmp
mkdir "$hash_tmp/bin" "$hash_tmp/config"
printf 'export LMLINE_MODEL=hash-privacy\n' >"$hash_tmp/config/settings.bash"
printf 'printf\n' >"$hash_tmp/list"
export LMLINE_CONFIG_DIR=$hash_tmp/config LMLINE_BIND_KEYS=0 TEXT='()example'
# /bin/sh does not silently discard protected transport before recording it.
# Record NUL-delimited bytes, then use the real selected tool for exact output.
cat >"$hash_tmp/record-hash" <<'TOOL'
#!/bin/sh
/usr/bin/env -0 >>"$HASH_TEST_DIR/environment"
printf '%s\n' "${0##*/} $*" >>"$HASH_TEST_DIR/calls"
case ${HASH_TEST_FAILURE-} in
  fail) exit 1 ;;
  empty) exit 0 ;;
  partial) printf 'partial\n'; exit 1 ;;
esac
case ${0##*/} in
  cksum) exec "$HASH_REAL_CKSUM" ;;
  sha256sum) exec "$HASH_REAL_SHA256SUM" ;;
  shasum) exec "$HASH_REAL_SHASUM" -a 256 ;;
esac
TOOL
chmod +x "$hash_tmp/record-hash"
export HASH_REAL_CKSUM
HASH_REAL_CKSUM=$(command -v cksum)
HASH_REAL_AWK=$(command -v awk)
export HASH_REAL_AWK
# Keep only selected hash tools on PATH to exercise both SHA variants/fallback.
for tool in bash awk sort cut; do ln -s "$(command -v "$tool")" "$hash_tmp/bin/$tool"; done
ln -s "$hash_tmp/record-hash" "$hash_tmp/bin/cksum"
cat >"$hash_tmp/check.bash" <<'CHECK'
set -e
# A same-name live function must not disguise protected inherited transport.
foo() { :; }
if [[ $2 == ordinary ]]; then
  foo%bar() { : HASH_BODY_MARKER; }
  export -f foo foo%bar
fi
before=$(declare -Fx)
source "$1/lmline/init.bash"
LMLINE_SUGGESTED_COMMANDS_FILE=$HASH_TEST_DIR/list
LMLINE_PROJECT_MARKERS_FILE=$HASH_TEST_DIR/list
if [[ $2 == blocked ]]; then
  [[ -z $__LMLINE_SETTINGS_CKSUM && ! -e $HASH_TEST_DIR/calls ]]
  __LMLINE_SETTINGS_CKSUM=unchanged
  __lmline_reload_settings_if_changed "$LMLINE_CONFIG_DIR"
  [[ $__LMLINE_SETTINGS_CKSUM == unchanged && ! -e $HASH_TEST_DIR/calls ]]
  for helper in __lmline_settings_cksum __lmline_sandbox_hash \
      __lmline_async_settings_key __lmline_async_frontend_key __lmline_hash_stdin \
      __lmline_suggested_commands_key __lmline_project_markers_key; do
    if "$helper" generate <"$LMLINE_CONFIG_DIR/settings.bash"; then exit 1; fi
    [[ ! -e $HASH_TEST_DIR/calls ]]
  done
else
  expected=$("$HASH_REAL_CKSUM" <"$LMLINE_CONFIG_DIR/settings.bash")
  [[ $__LMLINE_SETTINGS_CKSUM == "$expected" ]]
  [[ $(__lmline_settings_cksum <"$LMLINE_CONFIG_DIR/settings.bash") == "$expected" ]]
  __LMLINE_SETTINGS_CKSUM=outdated
  __lmline_reload_settings_if_changed "$LMLINE_CONFIG_DIR"
  [[ $__LMLINE_SETTINGS_CKSUM == "$expected" ]]
  real=$HASH_REAL_CKSUM; args=()
  if [[ $3 == cksum ]]; then
    sandbox_expected=${expected%% *}
    frontend_expected=$(printf '%s\0%s\0' "$LMLINE_ENGINE" engine | "$HASH_REAL_CKSUM")
    frontend_expected=${frontend_expected%% *}
  else
    if [[ $3 == sha256sum ]]; then real=$HASH_REAL_SHA256SUM; args=()
    else real=$HASH_REAL_SHASUM; args=(-a 256); fi
    sandbox_expected=$("$real" "${args[@]}" <"$LMLINE_CONFIG_DIR/settings.bash")
    sandbox_expected=${sandbox_expected:0:16}
    frontend_expected=$(printf '%s\0%s\0' "$LMLINE_ENGINE" engine | "$real" "${args[@]}")
    frontend_expected=${frontend_expected%% *}
  fi
  [[ $(__lmline_sandbox_hash <"$LMLINE_CONFIG_DIR/settings.bash") == "$sandbox_expected" ]]
  [[ $(__lmline_async_frontend_key generate) == "$frontend_expected" ]]
  [[ -n $(__lmline_async_settings_key) ]]
  # Custom PATH executables retain the established stdin-only interface;
  # hash raw bytes and freshly collected membership separately, preserving NULs.
  for helper in __lmline_suggested_commands_key __lmline_project_markers_key; do
    membership=$(printf 'printf\n' | "$real" "${args[@]}")
    if [[ $helper == __lmline_project_markers_key ]]; then
      membership=$(printf 1 | "$real" "${args[@]}")
    fi
    membership=${membership%% *}
    previous=
    for bytes in first second; do
      printf 'printf\n# raw\0%s\n' "$bytes" >"$LMLINE_SUGGESTED_COMMANDS_FILE"
      if [[ $helper == __lmline_project_markers_key ]]; then
        printf 'kind\t%s\n# raw\0%s\n' "$HASH_TEST_DIR/config" "$bytes" >"$LMLINE_PROJECT_MARKERS_FILE"
      fi
      expected=$("$real" "${args[@]}" <"$LMLINE_SUGGESTED_COMMANDS_FILE")
      : >"$HASH_TEST_DIR/calls"
      key=$("$helper")
      [[ $key == "${expected%% *}:$membership" && $key != "$previous" ]]
      calls_for_key=0
      while IFS= read -r call; do
        if [[ $3 == shasum ]]; then
          [[ $call == 'shasum -a 256' ]] || exit 1
        else
          [[ $call == "$3 " ]] || exit 1
        fi
        calls_for_key=$((calls_for_key + 1))
      done <"$HASH_TEST_DIR/calls"
      [[ $calls_for_key == 2 ]]
      previous=$key
    done
    # A cached wrapper wins even when PATH names the real system executable.
    # Neither lookup nor hashing may alter the caller's exact command cache.
    (
      PATH=$HASH_TEST_DIR/cached-bin
      export PATH
      hash -p "$HASH_TEST_DIR/bin/$3" "$3"
      hash -p "$real" unrelated_cached_command
      cache_before=$(builtin hash -l)
      : >"$HASH_TEST_DIR/calls"
      "$helper" >"$HASH_TEST_DIR/cached-key" || exit 1
      key=$(<"$HASH_TEST_DIR/cached-key")
      [[ $key == "${expected%% *}:$membership" ]] || exit 1
      [[ $(builtin hash -l) == "$cache_before" ]] || exit 1
      calls_for_key=0
      while IFS= read -r call; do
        if [[ $3 == shasum ]]; then
          [[ $call == 'shasum -a 256' ]] || exit 1
        else
          [[ $call == "$3 " ]] || exit 1
        fi
        calls_for_key=$((calls_for_key + 1))
      done <"$HASH_TEST_DIR/calls"
      [[ $calls_for_key == 2 ]]
    ) || exit 1
    # An stdin-based shell-function hasher retains the former two-call contract.
    if [[ $3 == sha256sum ]]; then
      ( PATH="$PATH:/bin:/usr/bin"; export PATH
        sha256sum() { cat; }
        __lmline_prepare_hash_environment || exit 1
        set -o pipefail
        file_digest=$(__lmline_hash_stdin <"$LMLINE_SUGGESTED_COMMANDS_FILE")
        if [[ $helper == __lmline_project_markers_key ]]; then
          membership_digest=$(__lmline_project_markers_scan "$LMLINE_PROJECT_MARKERS_FILE" presence | __lmline_hash_stdin)
        else
          membership_digest=$(__lmline_collect_suggested_commands | __lmline_hash_stdin)
        fi
        [[ $("$helper") == "$file_digest:$membership_digest" ]]
      ) || exit 1
    fi
    for failure in fail empty partial; do
      if HASH_TEST_FAILURE=$failure "$helper" >/dev/null 2>&1; then exit 1; fi
    done
  done
  # A shell-local tool override still wins; all changes remain private.
  cksum() { printf 'custom checksum\n'; }
  export -f cksum
  [[ $(__lmline_settings_cksum) == 'custom checksum' ]]
  export -nf cksum
fi
[[ $(declare -Fx) == "$before" && $TEXT == '()example' ]]
CHECK
# Fail closed before the fake executable, not merely after its output is read.
for record in 'BASH_FUNC_foo%%=() { : HASH_BODY_MARKER; }' \
    'BASH_FUNC_bad name%%=() { : HASH_BODY_MARKER; }' \
    'BASH_FUNC_%%=HASH_BODY_MARKER' 'foo=() { : HASH_BODY_MARKER; }'; do
  rm -f "$hash_tmp/calls" "$hash_tmp/environment"
  env "$record" PATH="$hash_tmp/bin" bash --noprofile --norc -p -i \
    "$hash_tmp/check.bash" "$repo_dir" blocked cksum \
    >"$hash_tmp/stdout" 2>"$hash_tmp/stderr" || fail "protected hash boundary: $record"
  [[ ! -e $hash_tmp/calls ]] || fail "protected hash child ran"
done
# Malformed/legacy raw records can survive ordinary Bash startup too.
for record in 'BASH_FUNC_%%=HASH_BODY_MARKER' 'foo=() { : HASH_BODY_MARKER; }'; do
  env "$record" PATH="$hash_tmp/bin" bash --noprofile --norc -i \
    "$hash_tmp/check.bash" "$repo_dir" blocked cksum \
    >"$hash_tmp/stdout" 2>"$hash_tmp/stderr" || fail "ordinary residual hash boundary: $record"
done
ok "startup, reload and direct Bash hash paths reject residual function records"

for selected in cksum shasum sha256sum; do
  if [[ $selected != cksum ]]; then
    real_tool=$(command -v "$selected") || continue
    case $selected in
      sha256sum) export HASH_REAL_SHA256SUM=$real_tool ;;
      shasum) export HASH_REAL_SHASUM=$real_tool ;;
    esac
    ln -s "$hash_tmp/record-hash" "$hash_tmp/bin/$selected"
  fi
  rm -rf "$hash_tmp/cached-bin"
  mkdir "$hash_tmp/cached-bin"
  for tool in awk sort cut; do
    ln -s "$(command -v "$tool")" "$hash_tmp/cached-bin/$tool"
  done
  ln -s "$(command -v "$selected")" "$hash_tmp/cached-bin/$selected"
  for mode in clean ordinary protected; do
    rm -f "$hash_tmp/calls" "$hash_tmp/environment"
    options=()
    [[ $mode != protected ]] || options=(-p)
    PATH="$hash_tmp/bin" bash --noprofile --norc "${options[@]}" -i \
      "$hash_tmp/check.bash" "$repo_dir" "$mode" "$selected" \
      >"$hash_tmp/stdout" 2>"$hash_tmp/stderr" || fail "$mode hash output parity ($selected)"
    [[ -s $hash_tmp/calls ]] || fail "$mode hash tool was not exercised ($selected)"
    if grep -aEq 'HASH_BODY_MARKER|BASH_FUNC_' "$hash_tmp/environment"; then
      fail "$mode hash child received function transport ($selected)"
    fi
    text_seen=0
    while IFS= read -r -d '' env_entry; do
      if [[ $env_entry == 'TEXT=()example' ]]; then
        text_seen=1
        break
      fi
    done <"$hash_tmp/environment"
    [[ $text_seen == 1 ]] || fail "$mode hash child lost ordinary TEXT data ($selected)"
    grep -q "^$selected " "$hash_tmp/calls" || fail "custom PATH not used ($selected)"
  done
done
# Exercise the system-tool batch path through an inode-identical PATH symlink.
# Its parser must not inherit the private file or membership descriptors.
rm -f "$hash_tmp/bin/awk"
cat >"$hash_tmp/bin/awk" <<'AWK'
#!/usr/bin/env bash
printf x >>"$HASH_TEST_DIR/awk-counts"
if [[ ${HASH_TEST_BATCH-} == 1 ]]; then
  while IFS= read -r -d '' entry; do
    case $entry in
      LMLINE_CONFIG_DIR=*|LMLINE_USER_RULES_DIR=*|LMLINE_DEFAULTS_DIR=*|LMLINE_PROJECT_MARKERS_FILE=*|LMLINE_SUGGESTED_COMMANDS_FILE=*|LMLINE_INCLUDE_PROJECT_CONTEXT=*|LMLINE_INCLUDE_SUGGESTED_COMMANDS=*|BASH_FUNC_*%%=*)
        printf leaked >"$HASH_TEST_DIR/descriptor-leak"; exit 1 ;;
    esac
  done < <(/usr/bin/env -0)
fi
for fd_path in /dev/fd/*; do
  fd=${fd_path##*/}
  [[ $fd =~ ^[0-9]+$ && $fd -gt 2 ]] || continue
  case " $HASH_TEST_BASE_FDS " in *" $fd "*) continue ;; esac
  if [[ $fd_path -ef $HASH_TEST_DIR/list || $fd_path -ef $HASH_TEST_DIR/markers || -p $fd_path ]]; then
    printf leaked >"$HASH_TEST_DIR/descriptor-leak"
    exit 1
  fi
done
exec "$HASH_REAL_AWK" "$@"
AWK
chmod +x "$hash_tmp/bin/awk"
cat >"$hash_tmp/batch-check.bash" <<'CHECK'
set -e
source "$1/lmline/init.bash"
LMLINE_SUGGESTED_COMMANDS_FILE=$HASH_TEST_DIR/list
LMLINE_PROJECT_MARKERS_FILE=$HASH_TEST_DIR/markers
export HASH_TEST_BATCH=1
printf 'printf\n' >"$LMLINE_SUGGESTED_COMMANDS_FILE"
printf 'kind\tlist\n' >"$LMLINE_PROJECT_MARKERS_FILE"
if [[ ${2-} == blocked ]]; then
  : >"$HASH_TEST_DIR/awk-counts"
  if __lmline_project_markers_key >/dev/null; then exit 1; fi
  [[ ! -s $HASH_TEST_DIR/awk-counts ]]
  exit
fi
export LMLINE_CONFIG_DIR LMLINE_USER_RULES_DIR LMLINE_DEFAULTS_DIR
hash_private_function() { : HASH_BODY_MARKER; }
export -f hash_private_function
hash_args=()
[[ $HASH_TEST_SYSTEM_HASH_NAME != shasum ]] || hash_args=(-a 256)
# Keep an unrelated inherited pipe open to ensure the privacy check only
# attributes descriptors opened by this key helper.
exec {unrelated_fd}< <(printf 'unrelated\n')
# Ignore unrelated descriptors inherited from the CI/test runner; only new
# file/pipe descriptors opened by the key helper are private inputs.
HASH_TEST_BASE_FDS=' '
for fd_path in /dev/fd/*; do
  fd=${fd_path##*/}
  if [[ $fd =~ ^[0-9]+$ && $fd -gt 2 ]]; then
    HASH_TEST_BASE_FDS+="$fd "
  fi
done
export HASH_TEST_BASE_FDS
for helper in __lmline_suggested_commands_key __lmline_project_markers_key; do
  export -n LMLINE_PROJECT_MARKERS_FILE LMLINE_SUGGESTED_COMMANDS_FILE
  export -n LMLINE_INCLUDE_PROJECT_CONTEXT LMLINE_INCLUDE_SUGGESTED_COMMANDS
  if [[ $helper == __lmline_project_markers_key ]]; then
    export LMLINE_PROJECT_MARKERS_FILE LMLINE_INCLUDE_PROJECT_CONTEXT
  else
    export LMLINE_SUGGESTED_COMMANDS_FILE LMLINE_INCLUDE_SUGGESTED_COMMANDS
  fi
  previous=
  for state in first changed absent; do
    cd "$HASH_TEST_DIR"
    # Change file bytes without changing parsed presence, then only presence.
    if [[ $state != absent ]]; then
      printf 'kind\tlist\n# raw\0%s\n' "$state" >"$LMLINE_PROJECT_MARKERS_FILE"
    else
      cd "$HASH_TEST_DIR/config"
    fi
    if [[ $helper == __lmline_project_markers_key ]]; then
      file=$LMLINE_PROJECT_MARKERS_FILE
      membership=$(__lmline_project_markers_scan "$file" presence | "$HASH_TEST_SYSTEM_HASH_REAL" "${hash_args[@]}")
    else
      file=$LMLINE_SUGGESTED_COMMANDS_FILE
      membership=$(printf 'printf\n' | "$HASH_TEST_SYSTEM_HASH_REAL" "${hash_args[@]}")
    fi
    expected_file=$("$HASH_TEST_SYSTEM_HASH_REAL" "${hash_args[@]}" <"$file")
    : >"$HASH_TEST_DIR/awk-counts"
    path_before=$PATH pwd_before=$PWD exports_before=$(declare -Fx) cache_before=$(builtin hash -l)
    key=$("$helper")
    [[ $PATH == "$path_before" && $PWD == "$pwd_before" && $(declare -Fx) == "$exports_before" && $(builtin hash -l) == "$cache_before" ]]
    [[ $key == "${expected_file%% *}:${membership%% *}" && $(<"$HASH_TEST_DIR/awk-counts") == x ]]
    if [[ $helper == __lmline_project_markers_key ]]; then
      [[ $key != "$previous" ]]
      previous=$key
    fi
  done
  # Fail closed on producer failure even after it emitted valid partial data.
  if [[ $helper == __lmline_project_markers_key ]]; then
    ( __lmline_project_markers_scan() { printf 1; return 1; }
      ! "$helper" >/dev/null ) || exit 1
  fi
done
exec {unrelated_fd}<&-

CHECK
for system_hash_name in cksum shasum sha256sum; do
  system_hash_real=$(builtin command -p -v "$system_hash_name" 2>/dev/null) || continue
  rm -f "$hash_tmp/bin/sha256sum" "$hash_tmp/bin/shasum" "$hash_tmp/bin/cksum" "$hash_tmp/descriptor-leak"
  ln -s "$system_hash_real" "$hash_tmp/bin/$system_hash_name"
  HASH_TEST_SYSTEM_HASH_NAME=$system_hash_name \
  HASH_TEST_SYSTEM_HASH_REAL=$system_hash_real \
  PATH="$hash_tmp/bin" bash --noprofile --norc -i \
    "$hash_tmp/batch-check.bash" "$repo_dir" \
    >"$hash_tmp/stdout" 2>"$hash_tmp/stderr" || fail "system hash parity and descriptor isolation ($system_hash_name)"
  [[ ! -e $hash_tmp/descriptor-leak ]] || fail "system hash parser received private descriptors"
  for record in 'BASH_FUNC_%%=HASH_BODY_MARKER' 'foo=() { : HASH_BODY_MARKER; }'; do
    env "$record" HASH_TEST_SYSTEM_HASH_NAME="$system_hash_name" \
      HASH_TEST_SYSTEM_HASH_REAL="$system_hash_real" PATH="$hash_tmp/bin" \
      bash --noprofile --norc -p -i "$hash_tmp/batch-check.bash" "$repo_dir" blocked \
      >"$hash_tmp/stdout" 2>"$hash_tmp/stderr" || fail "system hash residual transport guard ($system_hash_name)"
  done
done
# Standalone settings hashing below always uses cksum.
rm -f "$hash_tmp/bin/cksum"
ln -s "$HASH_REAL_CKSUM" "$hash_tmp/bin/cksum"

# Modules must also provide safe hashing when sourced without interactive init.
# Keep an unrelated pipe open, as runners may do; only helper-owned descriptors
# opened after the standalone shell starts should count as privacy leaks.
exec {standalone_unrelated_fd}< <(printf 'unrelated\n')
standalone_status=0
PATH="$hash_tmp/bin" bash --noprofile --norc -ec '
  HASH_TEST_BASE_FDS=" "
  for fd_path in /dev/fd/*; do
    fd=${fd_path##*/}
    if [[ $fd =~ ^[0-9]+$ && $fd -gt 2 ]]; then
      HASH_TEST_BASE_FDS+="$fd "
    fi
  done
  export HASH_TEST_BASE_FDS
  source "$1/lmline/sandbox.bash"
  [[ -n $(__lmline_sandbox_hash </dev/null) ]]
  source "$1/lmline/config.bash"
  [[ $(__lmline_settings_cksum </dev/null) == "$("$HASH_REAL_CKSUM" </dev/null)" ]]
' _ "$repo_dir" || standalone_status=$?
exec {standalone_unrelated_fd}<&-
(( standalone_status == 0 )) || fail "standalone hash support"
ok "Bash hash paths preserve exact digests, tool resolution, caller exports and ordinary data"
