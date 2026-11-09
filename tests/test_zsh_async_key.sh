#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Risk: deferred Zsh identity hashing must remain exact, private and cancelable.
if ! command -v zsh >/dev/null 2>&1; then
  printf 'skip - zsh async key (zsh not found)\n'
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-zsh-key.XXXXXX")
trap 'rm -rf "$work"' EXIT
lmline_async_transport() { : never-serialize-this-function-body; }
export -f lmline_async_transport
# Bash transports exported functions using either modern BASH_FUNC_* names or
# the legacy valid-name serialization; require the caller fixture, not a
# platform-specific representation, before launching Zsh.
if ! env | grep -Eq '^(BASH_FUNC_lmline_async_transport%%=|lmline_async_transport=\(\) \{)'; then
  printf 'missing exported-function transport fixture\n' >&2
  exit 1
fi
mkdir "$work/bin" "$work/repo"
export ASYNC_KEY_WORK=$work ASYNC_KEY_REAL_GIT ASYNC_KEY_REAL_MKTEMP ASYNC_KEY_REAL_MV
ASYNC_KEY_REAL_GIT=$(command -v git)
ASYNC_KEY_REAL_MKTEMP=$(command -v mktemp)
ASYNC_KEY_REAL_MV=$(command -v mv)
export ASYNC_KEY_REAL_HASH
ASYNC_KEY_REAL_HASH=$(command -v sha256sum || command -v shasum)
cat >"$work/bin/gate" <<'GATE'
# Sourced only by the controlled startup/hash/publication probes.
trap 'printf stopped >"$ASYNC_KEY_WORK/stopped"; exit 143' TERM
exec 3<>"$ASYNC_KEY_WORK/gate"
printf '%s\n' "$$" >"$ASYNC_KEY_WORK/blocked"
IFS= read -r -t 20 -u 3 release || exit 98
GATE
cat >"$work/bin/sha256sum" <<'HASH'
#!/usr/bin/env bash
[[ ${ASYNC_KEY_PHASE-} != fail ]] || exit 1
if [[ ${ASYNC_KEY_PHASE-} == hash ]]; then
  if env | grep -q '^BASH_FUNC_' || env | grep -q '^lmline_async_transport=() {' || declare -F lmline_async_transport >/dev/null; then exit 97; fi
  source "$ASYNC_KEY_WORK/bin/gate"
fi
exec "$ASYNC_KEY_REAL_HASH" "$@"
HASH
cat >"$work/bin/mktemp" <<'TEMP'
#!/usr/bin/env bash
# Both frame-temp and key-temp mktemp invocations must be body-free; the
# caller frame is sanitized with the collected scrub names.
if [[ $1 == *.key.tmp.* || $1 == *.frame.* ]]; then
  if env | grep -q '^BASH_FUNC_' || env | grep -q '^lmline_async_transport=() {' || declare -F lmline_async_transport >/dev/null 2>&1; then exit 96; fi
  if [[ ${ASYNC_KEY_PHASE-} == startup && $1 == *.key.tmp.* ]]; then source "$ASYNC_KEY_WORK/bin/gate"; fi
fi
exec "$ASYNC_KEY_REAL_MKTEMP" "$@"
TEMP
cat >"$work/bin/mv" <<'MOVE'
#!/usr/bin/env bash
if [[ ${ASYNC_KEY_PHASE-} == publication && $1 == *.key.tmp.* ]]; then source "$ASYNC_KEY_WORK/bin/gate"; fi
exec "$ASYNC_KEY_REAL_MV" "$@"
MOVE
cat >"$work/bin/git" <<'GIT'
#!/usr/bin/env bash
printf used >"$ASYNC_KEY_WORK/git-used"
exec "$ASYNC_KEY_REAL_GIT" "$@"
GIT
cat >"$work/engine" <<'ENGINE'
#!/usr/bin/env bash
if env | grep -q '^BASH_FUNC_' || env | grep -q '^lmline_async_transport=() {' || declare -F lmline_async_transport >/dev/null 2>&1; then exit 96; fi
printf used >"$ASYNC_KEY_WORK/engine-used"
printf 'lmline-candidate: low\t-\t-\techo async-key\n'
ENGINE
chmod +x "$work/bin/"{sha256sum,mktemp,mv,git} "$work/engine"
mkfifo "$work/gate"
git -C "$work/repo" init -q
git -C "$work/repo" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
cat >"$work/probe.zsh" <<'ZSH'
source "$1/lmline/init.zsh"
TRAPZERR() { print -ru2 -- "probe assertion failed at ${funcfiletrace[1]}"; }
# A real controlling terminal makes both MONITOR states testable.
if [[ $3 == on ]]; then
  setopt monitor
  builtin zmodload -F zsh/files b:mv
else
  unsetopt monitor
  builtin zmodload -u zsh/files 2>/dev/null || true
fi
wait_file() {
  local i
  for i in {1..400}; do [[ -s $1 ]] && return; sleep 0.025; done
  print -ru2 -- "missing probe file: ${1:t}"
  return 1
}
assert_removed() {
  local -a remains=("$1"*(N))
  [[ ${#remains} == 0 ]]
}
state() {
  setopt
  umask
  builtin zmodload -L -F zsh/files 2>/dev/null || true
  whence -w rm mv
  trap
}
probe_name() { : never-serialize-this-function-body; }
trap '__lmline_zsh_async_cleanup' EXIT
cd "$2/repo"
export PATH="$2/bin:$PATH" ASYNC_KEY_PHASE=none
# Include colon/newline components, nonexported globals, arrays and local shadows.
typeset -g LMLINE_PROMPT_VERSION=$'3:custom\nversion'
typeset -g LMLINE_KEY_PRIVATE=$'private:scalar\nvalue'
typeset -ga LMLINE_KEY_ARRAY=(ignored array)
typeset -g LMLINE_KEY_SHADOW=global
parity() {
  local LMLINE_KEY_SHADOW=local
  local expected before old
  BUFFER=$'# key:parity\nsecond line'; CURSOR=4
  before=$(state)
  expected=$(__lmline_zsh_request_key generate "$BUFFER" "$CURSOR")
  __lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
  [[ $BUFFER == $'# key:parity\nsecond line' && $CURSOR == 4 && $(state) == "$before" ]]
  old=$__LMLINE_ZSH_ASYNC_FILE
  wait "$__LMLINE_ZSH_ASYNC_PID"
  __lmline_zsh_async_read_key
  [[ $__LMLINE_ZSH_ASYNC_KEY == "$expected" && -s "$2/git-used" ]]
  [[ -z $(print -r -- "$old.frame."*(N) "$old.key.tmp."*(N)) ]]
  __lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
  [[ $BUFFER == 'echo async-key' && $(state) == "$before" ]]
  assert_removed "$old"
}
parity "$1" "$2"
# The platform may consume or discard the transport when starting Zsh. The
# scrubbed mktemp wrapper and engine fail if any function record/body survives.
parity "$1" "$2"
# All malformed/missing frames and a once-valid but stale key fail closed.
for corruption in missing empty truncated trailing extra stale; do
  BUFFER='# reject'; CURSOR=3
  __lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
  old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
  wait "$pid"
  case $corruption in
    missing) rm -f "$old.key" ;;
    empty) : >"$old.key" ;;
    truncated) printf incomplete >"$old.key" ;;
    trailing) printf garbage >>"$old.key" ;;
    extra) printf '\0' >>"$old.key" ;;
    stale) git symbolic-ref HEAD "refs/heads/changed-$3" ;;
  esac
  __lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
  [[ $BUFFER == '# reject' && $CURSOR == 3 && $__LMLINE_ZSH_ASYNC_PID != $pid ]]
  assert_removed "$old"
  __lmline_zsh_async_cleanup
done
# Blocking inside each isolated worker phase must not block launch or cleanup.
for ASYNC_KEY_PHASE in startup hash publication; do
  rm -f "$2/blocked" "$2/stopped" "$2/engine-used"
  BUFFER='# cancel'; CURSOR=2
  before=$(state)
  __lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
  old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
  wait_file "$2/blocked"
  blocked=$(<"$2/blocked")
  [[ ! -e "$2/engine-used" && $BUFFER == '# cancel' && $CURSOR == 2 ]]
  if [[ $ASYNC_KEY_PHASE == hash ]]; then
    frames=("$old.frame."*(N))
    [[ ${#frames} == 1 && ! -s "$old.key" ]]
    ! grep -a -q never-serialize-this-function-body "$frames[1]"
    # mktemp-created input and output files are private even with a loose umask.
    [[ $(find "$old"* -type f \( -name '*.frame.*' -o -name '*.key.tmp.*' \) ! -perm 600 -print) == '' ]]
  fi
  __lmline_zsh_async_cleanup
  [[ $(state) == "$before" ]]
  ! kill -0 "$pid" 2>/dev/null
  ! kill -0 "$blocked" 2>/dev/null
  [[ -s "$2/stopped" ]]
  assert_removed "$old"
done
# A second press while the key is still pending must not restart the active
# supervisor or do extra identity work. The hash gate stays held by the first
# worker; PID, file and gate owner are unchanged and nothing is reused.
ASYNC_KEY_PHASE=hash
rm -f "$2/blocked" "$2/stopped" "$2/engine-used"
BUFFER='# pending'; CURSOR=9
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
wait_file "$2/blocked"
blocked_first=$(<"$2/blocked")
[[ -n "$pid" && "$pid" != 0 ]]
[[ ! -e "$2/engine-used" ]]
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
[[ $__LMLINE_ZSH_ASYNC_PID == "$pid" && $__LMLINE_ZSH_ASYNC_FILE == "$old" ]]
[[ $(<"$2/blocked") == "$blocked_first" ]]
[[ ! -e "$2/engine-used" && $BUFFER == '# pending' ]]
BUFFER='# different'; CURSOR=11
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
[[ $__LMLINE_ZSH_ASYNC_PID == "$pid" && $__LMLINE_ZSH_ASYNC_FILE == "$old" ]]
[[ $(<"$2/blocked") == "$blocked_first" ]]
[[ $BUFFER == '# different' ]]
__lmline_zsh_async_cleanup
! kill -0 "$pid" 2>/dev/null
! kill -0 "$blocked_first" 2>/dev/null
[[ -s "$2/stopped" ]]
assert_removed "$old"
ASYNC_KEY_PHASE=none
# Supervisor output/temp files stay private with a loose umask, as do frame/key files.
saved_umask=$(umask)
umask 022
ASYNC_KEY_PHASE=hash
rm -f "$2/blocked" "$2/stopped" "$2/engine-used"
BUFFER='# umask'; CURSOR=7
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
wait_file "$2/blocked"
[[ $(find "$old"* -type f \( -name '*.frame.*' -o -name '*.key.tmp.*' -o -name '*.tmp.*' -o -name '*.status*' \) ! -perm 600 -print) == '' ]]
__lmline_zsh_async_cleanup
! kill -0 "$pid" 2>/dev/null
assert_removed "$old"
ASYNC_KEY_PHASE=none
rm -f "$2/engine-used"
BUFFER=$'# key:umask\nsecond'; CURSOR=4
expected=$(__lmline_zsh_request_key generate "$BUFFER" "$CURSOR")
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
wait "$pid"
__lmline_zsh_async_read_key
[[ $__LMLINE_ZSH_ASYNC_KEY == "$expected" ]]
[[ $(find "$old"* -type f ! -perm 600 -print) == '' ]]
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
[[ $BUFFER == 'echo async-key' ]]
assert_removed "$old"
umask "$saved_umask"
ASYNC_KEY_PHASE=fail
rm -f "$2/engine-used"
__lmline_zsh_generate_async '# failed' generate 0 >/dev/null 2>&1
old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
wait "$pid"
# Engine still runs on key failure, but no key is published or reused.
[[ ! -e "$old.key" && -e "$old.key.failed" && -s "$2/engine-used" && -s "$old" ]]
[[ $(find "$old"* -type f ! -perm 600 -print) == '' ]]
! __lmline_zsh_async_read_key
[[ -z "$__LMLINE_ZSH_ASYNC_KEY" ]]
BUFFER='# failed'; CURSOR=8
__lmline_zsh_generate_async "$BUFFER" generate "$CURSOR" >/dev/null 2>&1
[[ $BUFFER == '# failed' && $CURSOR == 8 && $__LMLINE_ZSH_ASYNC_PID != $pid ]]
__lmline_zsh_async_cleanup
assert_removed "$old"
# Cancel immediately too, before worker readiness is observable.
ASYNC_KEY_PHASE=none
__lmline_zsh_generate_async '# immediate' generate 0 >/dev/null 2>&1
old=$__LMLINE_ZSH_ASYNC_FILE; pid=$__LMLINE_ZSH_ASYNC_PID
__lmline_zsh_async_cleanup
! kill -0 "$pid" 2>/dev/null
assert_removed "$old"
ZSH
# pty.fork supplies the controlling terminal required by Zsh job control on
# both supported CI platforms; the deadline is a bounded test failure, not policy.
python3 - "$repo_dir" "$work" <<'PY'
import os, pty, select, signal, sys, time
for monitor in ('on', 'off'):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(LMLINE_CONFIG_DIR=sys.argv[2] + '/config-' + monitor,
                          LMLINE_ASYNC='1', LMLINE_ENGINE=sys.argv[2] + '/engine')
        os.execvp('zsh', ['zsh', '-efi', sys.argv[2] + '/probe.zsh', sys.argv[1], sys.argv[2], monitor])
    output = bytearray()
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 8192)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
    else:
        os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    if status:
        sys.stderr.buffer.write(output)
        sys.exit('async key probe failed (MONITOR=' + monitor + ')')
PY
ok 'zsh async key parity, framing, cancellation and state'
