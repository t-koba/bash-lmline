# Security

`lmline` inserts suggested commands into the shell editing buffer. It does not press Enter for normal generation and rewrite operations.

`Ctrl-x Ctrl-f` is different: it executes the current line once through `LMLINE_EXEC_BACKEND` in order to capture stdout, stderr, exit status, and backend name for repair suggestions. With the local backend, high-risk commands are refused and medium-risk commands require `LMLINE_FIX_ALLOW_MEDIUM=1`. With `microsandbox`, execution requires the `msb` CLI or a configured `LMLINE_MICROSANDBOX_COMMAND`.

Do not enable a remote provider unless you are comfortable sending shell context to that provider. By default, file contents and shell history are not sent.

`command_run` is disabled by default. When enabled, its bounded stdout/stderr is sent to the model as untrusted tool output. `LMLINE_EXEC_BACKEND=off` disables command execution. `LMLINE_EXEC_BACKEND=auto` uses the configured microsandbox CLI when `msb` is available; otherwise it uses the local backend. `lmline sandbox run` requires microsandbox and never falls back to local execution.

The microsandbox backend isolates command execution from the host process, but command output can still expose data from the sandbox image or command input. lmline does not claim network isolation for microsandbox because that is controlled by the upstream runtime and CLI options.

`lmline sandbox check` runs `msb --version` only. lmline does not install microsandbox automatically.

`lmline sandbox setup` bind-mounts the project root read-only by default and writes non-secret host environment metadata to `/etc/lmline-env.json` inside the sandbox. `--workspace writable` allows sandbox commands to write through to the project tree and should be used only for trusted workflows.

Project-local `.lmline.bash` files are parsed as `export LMLINE_NAME='value'` assignments only. They are not sourced as shell code. Lines that are not simple `LMLINE_*` assignments are ignored.

Debug tracing can save request/response payloads, accepted and rejected candidates, tool outputs, and captured output from `Ctrl-x Ctrl-f`. Keep tracing off unless you are actively debugging.

When `LMLINE_CACHE_TTL` is above 0, generated candidates and explanation text are stored under `~/.config/lmline/cache/` (directory mode `0700`, files user-only). Cached entries can contain your prompt lines and model responses; expired entries are pruned opportunistically, and `rm -rf ~/.config/lmline/cache` clears the cache at any time. `fix` and `clip` responses are never cached.

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

Please report vulnerabilities privately through the repository's security advisory mechanism if available.
