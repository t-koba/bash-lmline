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
case ${0##*/} in
  cksum) exec "$HASH_REAL_CKSUM" "$@" ;;
  sha256sum) exec "$HASH_REAL_SHA256SUM" "$@" ;;
  shasum) exec "$HASH_REAL_SHASUM" "$@" ;;
esac
TOOL
chmod +x "$hash_tmp/record-hash"
export HASH_REAL_CKSUM
HASH_REAL_CKSUM=$(command -v cksum)
export HASH_REAL_AWK=$(command -v awk)
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
if [[ $2 == blocked ]]; then
  [[ -z $__LMLINE_SETTINGS_CKSUM && ! -e $HASH_TEST_DIR/calls ]]
  __LMLINE_SETTINGS_CKSUM=unchanged
  __lmline_reload_settings_if_changed "$LMLINE_CONFIG_DIR"
  [[ $__LMLINE_SETTINGS_CKSUM == unchanged && ! -e $HASH_TEST_DIR/calls ]]
  for helper in __lmline_settings_cksum __lmline_sandbox_hash \
      __lmline_async_settings_key __lmline_async_frontend_key __lmline_hash_stdin \
      __lmline_suggested_commands_key; do
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
  # Batch exactly two private streams once, preserving separate raw-byte and
  # membership digests even for NUL bytes that shell variables cannot hold.
  membership=$(printf 'printf\n' | "$real" "${args[@]}")
  membership=${membership%% *}
  previous=
  for bytes in first second; do
    printf 'printf\n# raw\0%s\n' "$bytes" >"$LMLINE_SUGGESTED_COMMANDS_FILE"
    expected=$("$real" "${args[@]}" <"$LMLINE_SUGGESTED_COMMANDS_FILE")
    : >"$HASH_TEST_DIR/calls"
    key=$(__lmline_suggested_commands_key)
    [[ $key == "${expected%% *}:$membership" && $key != "$previous" ]]
    IFS= read -r call <"$HASH_TEST_DIR/calls"
    [[ $call == "$3 "*'/dev/fd/'*' /dev/fd/'* && $(<"$HASH_TEST_DIR/calls") == "$call" ]]
    previous=$key
  done
  # An stdin-based shell-function hasher retains the former two-call contract.
  if [[ $3 == sha256sum ]]; then
    ( PATH="$PATH:/bin:/usr/bin"; export PATH
      sha256sum() { cat; }
      __lmline_prepare_hash_environment || exit 1
      set -o pipefail
      file_digest=$(__lmline_hash_stdin <"$LMLINE_SUGGESTED_COMMANDS_FILE")
      membership_digest=$(__lmline_collect_suggested_commands | __lmline_hash_stdin)
      [[ $(__lmline_suggested_commands_key) == "$file_digest:$membership_digest" ]]
    ) || exit 1
  fi
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
# The output parser must not inherit descriptors carrying the private streams.
rm "$hash_tmp/bin/awk"
cat >"$hash_tmp/bin/awk" <<'AWK'
#!/usr/bin/env bash
case ${1-} in
  'NR == 1 '*)
    IFS=' ' read -r tool file_fd membership_fd <"$HASH_TEST_DIR/calls" || exit 1
    if [[ $file_fd -ef $HASH_TEST_DIR/list || -p $membership_fd ]]; then
      printf leaked >"$HASH_TEST_DIR/awk-leak"
      exit 1
    fi
    ;;
esac
exec "$HASH_REAL_AWK" "$@"
AWK
chmod +x "$hash_tmp/bin/awk"
rm -f "$hash_tmp/calls" "$hash_tmp/environment" "$hash_tmp/awk-leak"
PATH="$hash_tmp/bin" bash --noprofile --norc -i \
  "$hash_tmp/check.bash" "$repo_dir" clean sha256sum \
  >"$hash_tmp/stdout" 2>"$hash_tmp/stderr" || fail "hash stream descriptor isolation"
[[ ! -e $hash_tmp/awk-leak ]] || fail "private file/membership descriptor reached awk"
# Modules must also provide safe hashing when sourced without interactive init.
PATH="$hash_tmp/bin" bash --noprofile --norc -ec '
  source "$1/lmline/sandbox.bash"
  [[ -n $(__lmline_sandbox_hash </dev/null) ]]
  source "$1/lmline/config.bash"
  [[ $(__lmline_settings_cksum </dev/null) == "$("$HASH_REAL_CKSUM" </dev/null)" ]]
' _ "$repo_dir" || fail "standalone hash support"
ok "Bash hash paths preserve exact digests, tool resolution, caller exports and ordinary data"
