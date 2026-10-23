# Security

`lmline` inserts suggested commands into the shell editing buffer. It never executes a candidate on its own; the paths that run a command are `Ctrl-x Ctrl-f` (fix), the opt-in `command_run` tool, and `lmline sandbox run`, all of which the user invokes or enables and all of which are risk-gated. A fourth path can run a program without the user invoking it, but only when explicitly opted in with `LMLINE_TOOL_COMMAND_INFO=1` (only the exact value `1` enables it; unset and any other value fail closed): the `command_info` tool then probes an external program the model names by running it with the fixed flag `--version` under a short timeout (`LMLINE_TOOL_INFO_TIMEOUT`, two seconds by default). On macOS a fixed list of eleven programs that do not accept the flag is not probed at all (`sed`, `grep`, `find`, `xargs`, `date`, `head`, `tail`, `sort`, `uniq`, `nl`, `yes`); every other program is probed with the same flag, so a macOS program that does not accept `--version` answers with its usage message instead of a version. That probe is not restricted by the `local_commands.txt` list, so it can run any program on your `PATH`, and what the program prints is sent back to the model.

`Ctrl-x Ctrl-f` executes the current line once through `LMLINE_EXEC_BACKEND` in order to capture stdout, stderr, exit status, and backend name for repair suggestions. With the local backend, high-risk commands are refused and medium-risk commands require `LMLINE_FIX_ALLOW_MEDIUM=1`. With `microsandbox`, execution requires the `msb` CLI or a configured `LMLINE_MICROSANDBOX_COMMAND`.

Do not enable a remote provider unless you are comfortable sending shell context to that provider. By default, file contents and shell history are not sent.

Remote-provider requests use the host's installed `curl` and its linked TLS and protocol libraries. Keep
this transport stack security-patched through your operating system or package manager; distributions may
backport fixes, so check vendor advisories rather than relying only on upstream version numbers. For
example, [curl's CVE-2026-92392 advisory](https://curl.se/docs/CVE-2026-92392.html) covers HTTP/2 upload
handling. The `-q` flag used by lmline isolates requests from implicit curlrc settings; it does not
disable HTTP/2 or replace dependency updates.

`command_run` is disabled by default. When enabled, its bounded stdout/stderr is sent to the model as untrusted tool output. `LMLINE_EXEC_BACKEND=off` disables command execution. `LMLINE_EXEC_BACKEND=auto` uses the configured microsandbox CLI when `msb` is available; otherwise it uses the local backend. `lmline sandbox run` requires microsandbox and never falls back to local execution.

The command-execution timeout helper uses GNU `timeout` when available. Its portable
fallback cancels the launched job's isolated process group with TERM, then KILL
after a one-second grace period, even if the group leader exits on TERM.
Processes that intentionally detach or change process group (for example via
`setpgid` or `setsid`) are outside this cancellation scope. A local execution
deadline is not a security sandbox.

The microsandbox backend isolates command execution from the host process, but command output can still expose data from the sandbox image or command input. lmline does not claim network isolation for microsandbox because that is controlled by the upstream runtime and CLI options.

`lmline sandbox check` runs `msb --version` only. lmline does not install microsandbox automatically.

`lmline sandbox setup` bind-mounts the project root read-only by default and writes non-secret host environment metadata to `/etc/lmline-env.json` inside the sandbox. `--workspace writable` allows sandbox commands to write through to the project tree and should be used only for trusted workflows.

Project-local `.lmline.bash` files are parsed as `export LMLINE_NAME='value'` assignments only. They are not sourced as shell code. Lines that are not simple `LMLINE_*` assignments are ignored.

Project files are ignored unless the user enables `LMLINE_PROJECT_CONFIG` in their own settings or environment (default `0`). Without that opt-in, a cloned repository cannot replace the engine executable, redirect the provider URL, or re-enable execution and file tools the user left disabled; a project file cannot enable the opt-in by itself.

Debug tracing can save request/response payloads, accepted and rejected candidates, tool outputs, and captured output from `Ctrl-x Ctrl-f`. Keep tracing off unless you are actively debugging.

When `LMLINE_CACHE_TTL` is above 0, generated candidates and explanation text are stored under `~/.config/lmline/cache/` (directory mode `0700`, files user-only). Cached entries can contain your prompt lines and model responses; expired entries are pruned opportunistically, and `rm -rf ~/.config/lmline/cache` clears the cache at any time. `fix` and `clip` responses are never cached.

The suggestion log under `~/.config/lmline/history/` (directory mode `0700`, log file mode `0600`) records the commands you accepted: their text, the working directory, and the time. It is readable by `lmline history show` and `lmline history tendencies`, and you can delete it at any time.

For registered endpoints, store API keys with endpoint-scoped secrets:

```bash
lmline endpoint set-secret ENDPOINT
```

This stores the key under `~/.config/lmline/secrets/` with mode `0600` and records only the secret file path in `endpoints.tsv`. `lmline use ENDPOINT MODEL` writes that path to `LMLINE_API_KEY_FILE`, so the selected endpoint's secret file is the active credential source.

If you bypass endpoint/model profiles and configure `LMLINE_BASE_URL` directly, store the active API key with:

```bash
install -m 600 /dev/null ~/.config/lmline/secrets/manual-api-key.secret
$EDITOR ~/.config/lmline/secrets/manual-api-key.secret
lmline config set LMLINE_API_KEY_FILE ~/.config/lmline/secrets/manual-api-key.secret
```

Do not put raw API keys in `settings.bash`, project config, shell history, or trace files.

API keys are passed to `curl` through `-H @file` header files created with user-only permissions, not on the `curl` command line, so credentials do not appear in process listings (`ps`). Trace directories and the secrets directory are created with mode `0700`.

A ChatGPT subscription sign-in stores a different kind of credential: an OAuth refresh token that grants access to the ChatGPT plan.

```bash
lmline chatgpt login
```

The credential lives in `~/.config/lmline/chatgpt/credentials.json` (file mode `0600`, directory mode `0700`) next to a stable host identifier in `~/.config/lmline/chatgpt/host-id`. The file holds the access token, the refresh token, and the ID token. The client refuses to use a credential file that other users can read and says how to fix it, and `lmline chatgpt status` never prints a token.

The subscription token is sent only to the OpenAI API. A loopback proxy is accepted, and it forwards the token to whoever runs it. The token is never written to a trace file, a log, or a prompt, and it never appears in a process listing.

`lmline chatgpt logout` revokes the refresh token at the provider and then clears the local tokens. When the revocation cannot be confirmed, the local tokens are still cleared and the command says so. If the machine is compromised, run `lmline chatgpt logout`, revoke the session in the ChatGPT account, and delete `~/.config/lmline/chatgpt/`.

Please report vulnerabilities privately through the repository's security advisory mechanism if available.
