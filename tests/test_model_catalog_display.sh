#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/lmline-catalog-display.XXXXXX")
trap 'rm -rf "$work"' EXIT
raw_model=$'provider_\302\23552;c;payload\302\234suffix'
raw_start=$'\302\235'
raw_end=$'\302\234'
unicode_model='unicode-模型'
config_dir=$work/config
lmline=$repo_dir/lmline/lmline
mkdir -p "$config_dir"
LMLINE_CONFIG_DIR="$config_dir" "$lmline" endpoint add catalog https://catalog.example/v1 >/dev/null
printf 'catalog\t%s\t\t\t\tchat\ncatalog\tordinary-model\t\t\t\tchat\ncatalog\t%s\t\t\t\tchat\n' "$raw_model" "$unicode_model" >"$config_dir/models.tsv"

model_list=$(LMLINE_CONFIG_DIR="$config_dir" "$lmline" model list catalog)
expected_list=$'catalog\tprovider_suffix\t\t\t\tchat\ncatalog\tordinary-model\t\t\t\tchat\ncatalog\tunicode-模型\t\t\t\tchat'
[[ "$model_list" == "$expected_list" ]] || fail 'human model list sanitizes only the catalog ID and preserves ordinary names'
[[ "$model_list" != *"$raw_start"* && "$model_list" != *"$raw_end"* ]] || fail 'human model list contains no C1 bytes'
unknown_model=$'provider_\302\23552;c;payload\302\234missing'
if LMLINE_CONFIG_DIR="$config_dir" "$lmline" use catalog "$unknown_model" >/dev/null 2>"$work/unknown-use.err"; then
  fail 'unknown model selection is rejected'
fi
unknown_use_error=$(cat "$work/unknown-use.err")
[[ "$unknown_use_error" == *'unknown model for catalog: provider_missing'* ]] || fail 'unknown model errors use a safe display label'
[[ "$unknown_use_error" != *"$raw_start"* && "$unknown_use_error" != *"$raw_end"* ]] || fail 'unknown model selection error contains no raw C1 bytes'
if LMLINE_CONFIG_DIR="$config_dir" "$lmline" model remove catalog "$unknown_model" >/dev/null 2>"$work/unknown-remove.err"; then
  fail 'unknown model removal is rejected'
fi
unknown_remove_error=$(cat "$work/unknown-remove.err")
[[ "$unknown_remove_error" == *'unknown model for catalog: provider_missing'* ]] || fail 'unknown model removal errors use a safe display label'
[[ "$unknown_remove_error" != *"$raw_start"* && "$unknown_remove_error" != *"$raw_end"* ]] || fail 'unknown model removal error contains no raw C1 bytes'

# The default model-candidate output is display-safe; shell integrations opt in
# to the lossless machine transport explicitly.
completion_display=$(LMLINE_CONFIG_DIR="$config_dir" "$lmline" complete models catalog)
[[ "$completion_display" == $'provider_suffix\nordinary-model\nunicode-模型' ]] || fail 'default completion output uses safe model labels'
[[ "$completion_display" != *"$raw_start"* && "$completion_display" != *"$raw_end"* ]] || fail 'default completion output contains no raw C1 bytes'
completion_raw=$(LMLINE_CONFIG_DIR="$config_dir" "$lmline" complete models --raw catalog)
grep -Fxq "$raw_model" <<<"$completion_raw" || fail 'machine completion transport preserves the raw ID'
grep -Fxq 'ordinary-model' <<<"$completion_raw" || fail 'machine completion transport preserves ordinary IDs'
grep -Fxq "$unicode_model" <<<"$completion_raw" || fail 'machine completion transport preserves Unicode IDs'
printf 'missing-endpoint\t%s\t\t\t\tchat\n' "$raw_model" >>"$config_dir/models.tsv"

# Selection and status matching continue to use the exact raw identifier.
if LMLINE_CONFIG_DIR="$config_dir" "$lmline" use catalog >/dev/null 2>"$work/use.err"; then
  fail 'ambiguous model selection requires an explicit ID'
fi
use_error=$(cat "$work/use.err")
[[ "$use_error" != *"$raw_start"* && "$use_error" != *"$raw_end"* ]] || fail 'model-choice guidance contains no raw C1 bytes'
LC_ALL=C printf -v quoted_model '%q' "$raw_model"
[[ "$use_error" == *"lmline use catalog $quoted_model"* ]] || fail 'model-choice guidance uses a reversible shell word'
LC_ALL=C printf -v quoted_unicode '%q' "$unicode_model"
[[ "$use_error" == *"lmline use catalog $quoted_unicode"* ]] || fail 'Unicode model-choice guidance uses a reversible shell word'
LMLINE_CONFIG_DIR="$config_dir" "$lmline" use catalog "$raw_model" >/dev/null
saved_model=$(
  # shellcheck disable=SC1090
  source "$config_dir/settings.bash"
  printf '%s' "$LMLINE_MODEL"
)
[[ "$saved_model" == "$raw_model" ]] || fail 'explicit selection stores the exact raw catalog ID'
current_out=$(LMLINE_CONFIG_DIR="$config_dir" "$lmline" current)
[[ "$current_out" == *$'model=provider_suffix\n'* && "$current_out" == *'profile_status=matched'* ]] || fail 'current status displays safely while matching the raw ID'
[[ "$current_out" != *"$raw_start"* && "$current_out" != *"$raw_end"* ]] || fail 'current output contains no raw C1 bytes'
doctor_out=$(LMLINE_CONFIG_DIR="$config_dir" "$lmline" doctor)
[[ "$doctor_out" == *$'model=provider_suffix\n'* ]] || fail 'doctor displays the selected model safely'
[[ "$doctor_out" != *"$raw_start"* && "$doctor_out" != *"$raw_end"* ]] || fail 'doctor output contains no raw C1 bytes'
[[ "$doctor_out" == *'model references unknown endpoint: missing-endpoint/provider_suffix'* ]] || fail 'doctor profile checks safely display an orphaned catalog ID'

# Refresh/removal summaries and cached status/meta use the same safe display label.
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '{"data":[{"id":"ordinary-model"}]}\n'
CURL
chmod +x "$work/bin/curl"
PATH="$work/bin:$PATH" LMLINE_CONFIG_DIR="$config_dir" "$lmline" model refresh catalog >"$work/refresh.out" 2>"$work/refresh.err" || fail 'catalog refresh with a removed C1 model succeeds'
refresh_error=$(cat "$work/refresh.err")
[[ "$refresh_error" == *'removed models: provider_suffix'* ]] || fail 'refresh summary displays a sanitized removed ID'
[[ "$refresh_error" == *'selected model provider_suffix is no longer served'* ]] || fail 'removed-selection warning displays a sanitized ID'
[[ "$refresh_error" != *"$raw_start"* && "$refresh_error" != *"$raw_end"* ]] || fail 'refresh output contains no raw C1 bytes'

# Cache hits display the configured catalog ID through the metadata sanitizer.
# shellcheck source=lmline/context.bash
source "$repo_dir/lmline/context.bash"
# shellcheck source=lmline/chat.bash
source "$repo_dir/lmline/chat.bash"
mode=explain
output_format=plain
cache_file=$work/cache
printf 'cached response' >"$cache_file"
LMLINE_MODEL=$raw_model
__lmline_cache_emit >"$work/cache.out" 2>"$work/cache.err"
[[ $(cat "$work/cache.out") == 'cached response' ]] || fail 'cache hit still emits its response'
cache_error=$(cat "$work/cache.err")
[[ "$cache_error" == $'lmline-meta: model=provider_suffix tokens=cached tools=none time=0s\nlmline-status: m=provider_suffix; cached' ]] || fail 'cached status and metadata display a safe model label'
[[ "$cache_error" != *"$raw_start"* && "$cache_error" != *"$raw_end"* ]] || fail 'cached metadata contains no raw C1 bytes'

# Each shipped completion adapter inserts an encoded shell word which evaluates
# to the exact raw ID; only booleans are reported from these interactive PTYs.
python3 - "$repo_dir" "$work" <<'PY'
import errno, os, pty, select, signal, sys, time
repo, work = sys.argv[1:]
raw = 'provider_\u009d52;c;payload\u009csuffix'
unicode = 'unicode-\u30e2\u30c7\u30eb'
raw_endpoint = 'endpoint_\u009d52;c;payload\u009csuffix'
unicode_endpoint = 'unicode-endpoint-\u7aef\u70b9'
needle_start = b'\xc2\x9d'
needle_end = b'\xc2\x9c'
bindir = os.path.join(work, 'completion-bin')
os.makedirs(bindir, exist_ok=True)
fake = os.path.join(bindir, 'lmline')
with open(fake, 'w', encoding='utf-8') as f:
    f.write('''#!/usr/bin/env bash
if [[ ${1-} == complete && ${2-} == models ]]; then
  printf '%s\\n%s\\n%s\\n' "$LMLINE_TEST_CANDIDATE" "$LMLINE_TEST_SAFE_CANDIDATE" "$LMLINE_TEST_UNICODE_CANDIDATE"
elif [[ ${1-} == complete && ${2-} == endpoints && ${3-} == --raw ]]; then
  printf '%s\\n%s\\n%s\\n' "$LMLINE_TEST_ENDPOINT_CANDIDATE" "$LMLINE_TEST_SAFE_ENDPOINT_CANDIDATE" "$LMLINE_TEST_UNICODE_ENDPOINT_CANDIDATE"
elif [[ ${1-} == use ]]; then
  if [[ ${2-} == "$LMLINE_TEST_ENDPOINT_CANDIDATE" || ${2-} == "$LMLINE_TEST_SAFE_ENDPOINT_CANDIDATE" || ${2-} == "$LMLINE_TEST_UNICODE_ENDPOINT_CANDIDATE" ]]; then
    printf 'ENDPOINT_EXACT=true\\n'
  elif [[ ${3-} == "$LMLINE_TEST_CANDIDATE" || ${3-} == "$LMLINE_TEST_SAFE_CANDIDATE" || ${3-} == "$LMLINE_TEST_UNICODE_CANDIDATE" ]]; then
    printf 'MODEL_EXACT=true\\n'
  else
    printf 'EXACT=false\\n'
  fi
fi
''')
os.chmod(fake, 0o755)

for index, (shell, argv, setup, input_line) in enumerate((
    ('bash', ['bash', '--noprofile', '--norc', '-i'],
     'source ' + os.path.join(repo, 'lmline/completions/lmline.bash'),
     b'lmline use catalog provider_\t'),
    ('zsh', ['zsh', '-f', '-i'],
     'autoload -Uz compinit; compinit -i; source ' + os.path.join(repo, 'lmline/completions/_lmline') + '; compdef _lmline lmline',
     b'lmline use catalog provider_\t'))):
    print('pty - ' + shell + ': start', flush=True)
    ready_file = os.path.join(work, 'completion-ready-' + shell + '-' + str(index))
    try:
        os.unlink(ready_file)
    except FileNotFoundError:
        pass
    pid, fd = pty.fork()
    if pid == 0:
        env = os.environ.copy()
        env['PATH'] = bindir + os.pathsep + env.get('PATH', '')
        env['LMLINE_TEST_CANDIDATE'] = raw
        env['LMLINE_TEST_SAFE_CANDIDATE'] = 'ordinary-model'
        env['LMLINE_TEST_UNICODE_CANDIDATE'] = unicode
        env['LMLINE_TEST_ENDPOINT_CANDIDATE'] = raw_endpoint
        env['LMLINE_TEST_SAFE_ENDPOINT_CANDIDATE'] = 'ordinary-endpoint'
        env['LMLINE_TEST_UNICODE_ENDPOINT_CANDIDATE'] = unicode_endpoint
        env['LC_ALL'] = 'C'
        env['LMLINE_COMPLETION_READY'] = ready_file
        env['TERM'] = 'xterm'
        os.execvpe(shell, argv, env)
    transcript = bytearray()
    owned_group = None
    def write_all(data):
        deadline = time.monotonic() + 3
        pending = memoryview(data)
        while pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SystemExit(shell + ' PTY write timed out')
            try:
                _, writable, _ = select.select([], [fd], [], remaining)
                if writable:
                    written = os.write(fd, pending)
                    if written == 0:
                        raise SystemExit(shell + ' PTY write made no progress')
                    pending = pending[written:]
            except OSError as error:
                if error.errno not in (errno.EINTR, errno.EAGAIN, errno.EWOULDBLOCK):
                    raise SystemExit(shell + ' PTY write failed') from None
    def drain(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and len(transcript) < 65536:
            try:
                ready, _, _ = select.select([fd], [], [], 0.05)
                if ready:
                    chunk = os.read(fd, 4096)
                    if not chunk:
                        return
                    transcript.extend(chunk)
            except OSError as error:
                if error.errno in (errno.EINTR, errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                if error.errno == errno.EIO:  # PTY slave has closed on Linux.
                    return
                raise SystemExit(shell + ' PTY read failed') from None
    def wait_for_count(marker, count, seconds):
        deadline = time.monotonic() + seconds
        while transcript.count(marker) < count and time.monotonic() < deadline:
            drain(0.05)
        return transcript.count(marker) >= count
    exact = False
    endpoint_exact = False
    safe = False
    quoted_safe = False
    escaped_safe = False
    endpoint_quoted_safe = False
    endpoint_escaped_safe = False
    try:
        os.set_blocking(fd, False)
        drain(0.15)
        # pty.fork creates a session/group; never signal an unverified group.
        if os.getpgid(pid) != pid or pid == os.getpgrp():
            raise SystemExit(shell + ' PTY process group is not owned')
        owned_group = pid
        # Keep completion helpers in the owned group, including in interactive Bash.
        setup = 'set +m; ' + setup
        setup += '; printf ready > "$LMLINE_COMPLETION_READY"'
        write_all((setup + '\n').encode())
        deadline = time.monotonic() + 5
        while not os.path.exists(ready_file) and time.monotonic() < deadline:
            drain(0.05)
        if not os.path.exists(ready_file):
            raise SystemExit(shell + ' completion setup timed out')
        print('pty - ' + shell + ': setup ready', flush=True)
        write_all(input_line)
        drain(0.5)
        write_all(b'\r')
        exact = wait_for_count(b'MODEL_EXACT=true', 1, 3)
        write_all(b'lmline use catalog ordinary-\t')
        drain(0.5)
        write_all(b'\r')
        exact = exact and wait_for_count(b'MODEL_EXACT=true', 2, 3)
        write_all('lmline use catalog unicode-'.encode('utf-8') + b'\t')
        drain(0.5)
        write_all(b'\r')
        exact = exact and wait_for_count(b'MODEL_EXACT=true', 3, 3)

        endpoint_exact = True
        for count, prefix in enumerate((b'endpoint_', b'ordinary-endpoint', b'unicode-endpoint-'), 1):
            write_all(b'lmline use ' + prefix + b'\t')
            drain(0.5)
            write_all(b'\r')
            endpoint_exact = endpoint_exact and wait_for_count(b'ENDPOINT_EXACT=true', count, 3)

        before = len(transcript)
        write_all(b'lmline use catalog "provider_\t')
        drain(0.5)
        quoted = transcript[before:]
        quoted_safe = (needle_start not in quoted and needle_end not in quoted and b"$'" not in quoted)
        write_all(b'\x03')
        drain(0.15)

        before = len(transcript)
        write_all(b'lmline use catalog provider\\_\t')
        drain(0.5)
        escaped = transcript[before:]
        escaped_safe = (needle_start not in escaped and needle_end not in escaped and b"$'" not in escaped)
        write_all(b'\x03')
        drain(0.15)

        before = len(transcript)
        write_all(b'lmline use "endpoint_\t')
        drain(0.5)
        quoted_endpoint = transcript[before:]
        endpoint_quoted_safe = (needle_start not in quoted_endpoint and needle_end not in quoted_endpoint and b"$'" not in quoted_endpoint)
        write_all(b'\x03')
        drain(0.15)

        before = len(transcript)
        write_all(b'lmline use endpoint\\_\t')
        drain(0.5)
        escaped_endpoint = transcript[before:]
        endpoint_escaped_safe = (needle_start not in escaped_endpoint and needle_end not in escaped_endpoint and b"$'" not in escaped_endpoint)
        write_all(b'\x03')
        drain(0.15)
        safe = needle_start not in transcript and needle_end not in transcript
    finally:
        print('pty - ' + shell + ': cleanup', flush=True)
        cleanup_failed = False
        try:
            # Kill helpers before reaping the shell (and releasing its PID).
            if owned_group is not None:
                try:
                    os.killpg(owned_group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except OSError:
                    cleanup_failed = True
            # Also covers setup failures before group ownership was established.
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                cleanup_failed = True
            deadline = time.monotonic() + 2
            while True:
                try:
                    reaped, _ = os.waitpid(pid, os.WNOHANG)
                    if reaped == pid:
                        break
                except ChildProcessError:
                    break
                except OSError as error:
                    if error.errno != errno.EINTR:
                        cleanup_failed = True
                        break
                if time.monotonic() >= deadline:
                    cleanup_failed = True
                    break
                time.sleep(0.02)
        finally:
            try:
                os.close(fd)
            except OSError:
                cleanup_failed = True
        if cleanup_failed:
            raise SystemExit(shell + ' PTY cleanup failed or timed out')
        print('pty - ' + shell + ': cleanup complete', flush=True)
    if not exact or not endpoint_exact or not safe or not quoted_safe or not escaped_safe or not endpoint_quoted_safe or not endpoint_escaped_safe:
        raise SystemExit(shell + ' profile completion safety failed (models=' + str(exact).lower() + ', endpoints=' + str(endpoint_exact).lower() + ', no_c1=' + str(safe).lower() + ', quoted=' + str(quoted_safe and endpoint_quoted_safe).lower() + ', escaped=' + str(escaped_safe and endpoint_escaped_safe).lower() + ')')
PY

ok 'model and endpoint completions are terminal-safe and lossless'
