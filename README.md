# lmline

`lmline` is a Bash/zsh line editor helper. It asks an OpenAI-compatible chat
completion endpoint for command candidates and inserts the selected candidate
into the current shell line buffer. It does not press Enter.

The bundled engine is `lmline/engine`. A replacement set with `LMLINE_ENGINE`
must implement [docs/engine-protocol.md](docs/engine-protocol.md).

## Install

```bash
./install.sh
```

The installer copies files under `~/.config/lmline/` by default and links
`lmline` into `~/.local/bin/`.

Temporary Bash session:

```bash
bash --rcfile "$HOME/.config/lmline/init.bash" -i
```

Temporary zsh session:

```zsh
source "$HOME/.config/lmline/init.zsh"
```

Permanent Bash setup:

```bash
if [[ $- == *i* ]]; then
  source "$HOME/.config/lmline/init.bash"
fi
```

Permanent zsh setup:

```zsh
source "$HOME/.config/lmline/init.zsh"
```

## Requirements

Interactive integration:

```text
bash 4.2+ with Readline bind -x, or zsh with ZLE
```

Bundled engine:

```text
curl 7.55+
jq
```

<details>
<summary>Optional commands used when available</summary>

```text
git         Git root, branch, and Git-root project config
find        file-name context for the files tool
timeout     bounded command-info probes, fix execution, and local command_run
sha256sum   cache/request keys; falls back to shasum, then cksum
sed/awk/sort/uniq
            context formatting and CLI display helpers
pbpaste/wl-paste/xclip/xsel/powershell.exe/tmux
            clipboard providers for lmline clip and Ctrl-x Ctrl-v
msb
            optional microsandbox CLI command backend
```

</details>

Install and test scripts also use common POSIX tools such as `install`, `ln`,
`chmod`, `mktemp`, and `rm`.

## Provider Setup

Register an endpoint and model, then activate it. Endpoint URLs are
API base paths. The engine uses the model profile's API format:
`chat`, `responses`, or `messages`. Model discovery uses the endpoint's model
catalog.

Common endpoint bases:

| Provider | Base URL note |
| --- | --- |
| LM Studio | `http://127.0.0.1:1234/v1` |
| Ollama | `http://127.0.0.1:11434/v1` |
| OpenAI | `https://api.openai.com/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` |
| Sakura AI Engine | `https://api.ai.sakura.ad.jp/v1` |
| Cloudflare Workers AI | account-scoped `/ai/v1` base plus separate models URL |
| OpenCode Go/Zen | `https://opencode.ai/zen/go/v1` or `https://opencode.ai/zen/v1` |

<details>
<summary>Command example: LM Studio</summary>

```bash
lmline endpoint add lmstudio http://127.0.0.1:1234/v1 --tool-mode auto
lmline model refresh lmstudio
lmline use lmstudio <model-id>
```

</details>

<details>
<summary>Command example: Ollama</summary>

```bash
lmline endpoint add ollama http://127.0.0.1:11434/v1 --tool-mode auto
lmline model refresh ollama
lmline use ollama <model-id>
```

</details>

<details>
<summary>Command example: OpenAI</summary>

```bash
lmline endpoint add openai https://api.openai.com/v1 --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret openai
lmline model refresh openai
lmline use openai <model-id>
```

</details>

<details>
<summary>Command example: OpenRouter</summary>

```bash
lmline endpoint add openrouter https://openrouter.ai/api/v1 --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret openrouter
lmline model refresh openrouter
lmline use openrouter <model-id>
```

</details>

<details>
<summary>Command example: Gemini OpenAI-compatible API</summary>

```bash
lmline endpoint add gemini https://generativelanguage.googleapis.com/v1beta/openai --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret gemini
lmline model refresh gemini
lmline use gemini <model-id>
```

</details>

<details>
<summary>Command example: Sakura AI Engine</summary>

```bash
lmline endpoint add sakura https://api.ai.sakura.ad.jp/v1 --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret sakura
lmline model refresh sakura
lmline use sakura <model-id>
```

</details>

<details>
<summary>Command example: Cloudflare Workers AI</summary>

```bash
export CLOUDFLARE_ACCOUNT_ID=<account-id>
CF_MODELS_URL="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/models/search"
lmline endpoint add workers-ai \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/ai/v1" \
  --auth-header Authorization --auth-scheme Bearer --tool-mode auto \
  --models-url "$CF_MODELS_URL"
lmline endpoint set-secret workers-ai
lmline model refresh workers-ai
lmline use workers-ai <model-id>
```

Cloudflare's base path includes the account ID. Its model catalog URL differs
from the chat base path, so set `--models-url` when registering the endpoint.
Use the
[Workers AI model catalog](https://developers.cloudflare.com/workers-ai/models/)
for current IDs.

</details>

<details>
<summary>Command example: OpenCode Go</summary>

```bash
lmline endpoint add opencode-go https://opencode.ai/zen/go/v1 \
  --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret opencode-go
lmline model refresh opencode-go
lmline use opencode-go <model-id>
```

</details>

<details>
<summary>Command example: OpenCode Zen</summary>

```bash
lmline endpoint add opencode-zen https://opencode.ai/zen/v1 \
  --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret opencode-zen
lmline model refresh opencode-zen
lmline use opencode-zen <model-id>
```

OpenCode model catalogs can include `/chat/completions`, `/responses`, and
`/messages` endpoints. `model refresh` stores the detected API format with each
model. Use direct API model IDs without the OpenCode config prefix such as
`opencode-go/` or `opencode/`. Use the OpenCode [Go](https://opencode.ai/docs/go)
and [Zen](https://opencode.ai/docs/zen) docs for current endpoint/model
mappings.

</details>

If model refresh is unavailable for an endpoint, register the model manually:

```bash
lmline model add ENDPOINT MODEL [--api-format chat|responses|messages]
lmline use ENDPOINT MODEL
```

`model refresh` reads `${BASE_URL%/}/models` by default. Use `--models-url` for
a different catalog URL, `--models-jq` for a different response shape, and
`--models-prefix`, `--models-include`, or `--models-exclude` to filter the
discovered candidates. Catalog metadata is used to store `chat`, `responses`,
or `messages` in each model profile. When the catalog does not expose usable
format metadata, lmline keeps the `chat` default; set `--api-format` manually
for models that require another API shape.

For endpoints that expect the raw API key in a custom header, use an empty auth
scheme:

```bash
lmline endpoint add myapi https://api.example/v1 --auth-header X-Api-Key --auth-scheme ''
```

`endpoint add` stores endpoint metadata in `~/.config/lmline/endpoints.tsv`.
`model add` and `model refresh` store models in `~/.config/lmline/models.tsv`.
`endpoint set-secret` stores the API key under `~/.config/lmline/secrets/` with
mode `0600`; TSV files store only the secret file path.

`endpoint add` and `model add` accept `--temperature`, `--max-tokens`, and
`--tool-mode`. `model add` also accepts `--api-format`. Model values override
endpoint values; empty model values fall back to endpoint values.

<details>
<summary>Profile command reference</summary>

```bash
lmline endpoint list
lmline endpoint add ENDPOINT BASE_URL [--auth-header NAME] [--auth-scheme SCHEME] [--temperature N] [--max-tokens N] [--tool-mode auto|openai|text|none] [--models-url URL] [--models-jq JQ] [--models-prefix PREFIX] [--models-include REGEX] [--models-exclude REGEX]
lmline endpoint remove ENDPOINT [--keep-secret]
lmline model add ENDPOINT MODEL [--temperature N] [--max-tokens N] [--tool-mode auto|openai|text|none] [--api-format chat|responses|messages]
lmline model list [ENDPOINT]
lmline model refresh ENDPOINT
lmline model remove ENDPOINT MODEL
lmline use ENDPOINT [MODEL]
lmline current
```

`lmline use ENDPOINT` is accepted only when exactly one model is registered for
that endpoint.

</details>

Direct environment configuration also works for keys that are not overridden by
settings files:

```bash
export LMLINE_BASE_URL=http://127.0.0.1:1234/v1
export LMLINE_MODEL=<model-id>
export LMLINE_API_KEY_FILE=~/.config/lmline/secrets/api-key.secret
```

## Configuration

`lmline config set KEY VALUE` writes `export LMLINE_NAME='value'` entries to
`~/.config/lmline/settings.bash`. `lmline config set` accepts an explicitly
empty value, for example `LMLINE_AUTH_SCHEME=''`.

Project settings use `./.lmline.bash`:

```bash
lmline config project-set LMLINE_ASYNC 1
lmline config project-unset LMLINE_ASYNC
lmline config project-get
```

Config files are loaded in this order:

1. Existing process environment.
2. `~/.config/lmline/settings.bash`.
3. `.lmline.bash` at the Git root, if `git` is available.
4. `.lmline.bash` in `$PWD`, if present.

Later files override earlier values. Unset settings use built-in defaults.
Config files are parsed as simple `export LMLINE_NAME='value'` assignments;
they are not sourced as shell code.

## Keys

| Key | Action |
| --- | --- |
| `Ctrl-x Ctrl-g` | Generate or complete without rewriting the existing command prefix |
| `Ctrl-x Ctrl-r` | Rewrite the current line |
| `Ctrl-x Ctrl-n` | Insert the next candidate |
| `Ctrl-x Ctrl-p` | Insert the previous candidate |
| `Ctrl-x Ctrl-e` | Explain the current line |
| `Ctrl-x Ctrl-f` | Execute the current line once and ask for a fix |
| `Ctrl-x Ctrl-v` | Ask about current clipboard text |

`Ctrl-x Ctrl-g` always calls `generate`. Empty input and lines starting with
`#` generate a new command from the request text. If the line already has a
command prefix, `generate` preserves that prefix and appends only the missing
suffix. Inline `#` intent markers also preserve everything before the marker.
Use `Ctrl-x Ctrl-r` for full-line replacement.

Default key settings:

```text
LMLINE_KEY_GENERATE=\C-x\C-g
LMLINE_KEY_REWRITE=\C-x\C-r
LMLINE_KEY_NEXT=\C-x\C-n
LMLINE_KEY_PREV=\C-x\C-p
LMLINE_KEY_EXPLAIN=\C-x\C-e
LMLINE_KEY_FIX=\C-x\C-f
LMLINE_KEY_CLIP=\C-x\C-v
```

zsh key settings use zsh notation, for example:

```zsh
lmline config set LMLINE_KEY_GENERATE '^G'
source ~/.config/lmline/init.zsh
```

Disable automatic binding and bind manually:

```bash
lmline config set LMLINE_BIND_KEYS 0
source ~/.config/lmline/init.bash
bind -x '"\C-g": __lmline_generate_widget'
```

## Candidate Handling

The engine filters candidates before printing them:

- one line only
- no control characters
- valid `bash -n`
- no environment-assignment-only command segment
- no direct directory operands for simple file readers such as `cat`
- command words available locally, except words containing `/`, configured shell syntax words, and command prefixes
- deduplicated
- truncated to `LMLINE_MAX_CANDIDATE_BYTES` when needed

Each accepted candidate is classified with `risk_patterns.tsv`. High-risk
candidates are inserted as comments prefixed with `# REVIEW REQUIRED:`.
Medium-risk candidates are inserted with a warning. Low-risk candidates are
inserted directly.

`Ctrl-x Ctrl-f` is the only interactive action that executes the current line.
With the local backend, it refuses high-risk commands and medium-risk commands
require `LMLINE_FIX_ALLOW_MEDIUM=1`. With `microsandbox`, the command runs
through the configured `msb` CLI backend.

## CLI

Use `lmline help [TOPIC...]` for command-specific help. Common commands:

```bash
lmline doctor [--check-api]
lmline endpoint add|list|set-secret|remove
lmline model add|list|refresh|remove
lmline use ENDPOINT [MODEL]
lmline config get|defaults|effective
lmline sandbox run -- COMMAND
```

<details>
<summary>CLI command reference</summary>

```bash
lmline doctor [--check-api]
lmline context [LINE...]
lmline command-exists COMMAND...
lmline command-info COMMAND...
lmline commands [QUERY]
lmline payload MODE [LINE...]
lmline sandbox setup [--name NAME] [--image IMAGE] [--workspace readonly|writable|none] [--root PATH] [--workdir PATH] [--timeout SECONDS]
lmline sandbox run [--name NAME] [--image IMAGE] [--timeout SECONDS] [--max-output BYTES] -- COMMAND
lmline sandbox check
lmline clip [QUESTION...]
lmline clip --status
lmline clip --providers
lmline clip --use PROVIDER
lmline clip --provider PROVIDER [QUESTION...]
lmline config get|defaults|effective
lmline config describe KEY
lmline config set KEY VALUE
lmline config unset KEY
lmline config project-get
lmline config project-set KEY VALUE
lmline config project-unset KEY
lmline endpoint add|list|set-secret|remove
lmline model add|list|refresh|remove
lmline use ENDPOINT [MODEL]
lmline current
lmline complete commands|subcommands COMMAND|settings|setting-values KEY
lmline complete endpoints|models [ENDPOINT]|clipboard-providers
lmline history show
lmline history tendencies
lmline risk COMMAND...
lmline help [TOPIC...]
lmline debug bindings
lmline debug on|off
lmline debug trace on|off
lmline keys
lmline explain COMMAND...
lmline enable
lmline disable
```

`payload` prints the chat request JSON and does not contact the provider.
`doctor --check-api` calls the configured endpoint's model catalog.
`sandbox run` requires the microsandbox CLI and never falls back to host
execution.
`config get` prints only persisted user settings. Use `config defaults` for the
full setting catalog, `config effective` for redacted effective values, and
`config describe KEY` for one setting's current value, default, allowed values,
and description.
Every top-level command and documented subcommand or payload mode accepts
`--help`.

</details>

## Sandbox Setup

The microsandbox CLI can run one-off commands, but lmline works best when
command checks and `Ctrl-x Ctrl-f` run in an environment that resembles the
user's project environment. Use a project-specific sandbox profile instead of
relying on the default `debian` image:

```bash
lmline config set LMLINE_MICROSANDBOX_COMMAND msb
lmline sandbox setup --image ghcr.io/example/project-dev:latest
```

<details>
<summary>Setup behavior and workspace mounts</summary>

`sandbox setup` creates or reuses a named sandbox, bind-mounts the current Git
root at `/workspace` by default, writes `/etc/lmline-env.json` with non-secret
host environment metadata, and checks command availability from
`local_commands.txt`, `suggested_commands.txt`, and
`LMLINE_MICROSANDBOX_REQUIRED_COMMANDS`. If required commands are missing, build
or choose an OCI image that contains them and run setup again.

The default workspace mount is read-only. Use `--workspace writable` only when
you deliberately want sandbox commands to write through to the project tree.
Use `--workspace none` for image-only checks.

After setup, persist the printed `next_config` commands in the project config.
Then `LMLINE_EXEC_BACKEND=microsandbox` uses `msb exec` in that named sandbox
instead of ephemeral `msb run`.

</details>

## Clipboard

Clipboard providers are configured in `clipboard_providers.tsv`:

```text
name<TAB>command<TAB>arg1<TAB>arg2...
```

`lmline clip` and `Ctrl-x Ctrl-v` read the selected provider as an argv array,
not through shell evaluation. The default `auto` provider uses the first
available configured provider. Clipboard text is redacted for common secret
patterns, truncated to `LMLINE_CLIP_MAX_INPUT_BYTES`, and sent as untrusted
pasted text.

```bash
lmline clip --status
lmline clip --providers
lmline clip --use auto
lmline clip --use macos
lmline clip --provider tmux 'question'
```

## Editable Data Files

Packaged defaults live under `lmline/defaults/` and are installed under
`~/.config/lmline/defaults/`.

Create a same-named file directly under `~/.config/lmline/` to override a
default for one user. Explicit `LMLINE_*_FILE` paths are strict: unreadable
paths fail instead of falling back to defaults.

<details>
<summary>Data-file names and formats</summary>

```text
suggested_commands.txt
file_search_excludes.txt
shell_syntax_words.txt
command_prefix_words.txt
risk_patterns.tsv
project_markers.tsv
clipboard_providers.tsv
local_commands.txt
doctor_required_commands.txt
doctor_optional_commands.txt
```

Or point to an explicit file:

```bash
lmline config set LMLINE_SUGGESTED_COMMANDS_FILE /path/to/suggested_commands.txt
lmline config set LMLINE_FILE_SEARCH_EXCLUDES_FILE /path/to/file_search_excludes.txt
lmline config set LMLINE_SHELL_SYNTAX_WORDS_FILE /path/to/shell_syntax_words.txt
lmline config set LMLINE_COMMAND_PREFIX_WORDS_FILE /path/to/command_prefix_words.txt
lmline config set LMLINE_RISK_PATTERNS_FILE /path/to/risk_patterns.tsv
lmline config set LMLINE_PROJECT_MARKERS_FILE /path/to/project_markers.tsv
lmline config set LMLINE_CLIPBOARD_PROVIDERS_FILE /path/to/clipboard_providers.tsv
lmline config set LMLINE_LOCAL_COMMANDS_FILE /path/to/local_commands.txt
lmline config set LMLINE_DOCTOR_REQUIRED_COMMANDS_FILE /path/to/doctor_required_commands.txt
lmline config set LMLINE_DOCTOR_OPTIONAL_COMMANDS_FILE /path/to/doctor_optional_commands.txt
```

File formats:

```text
risk_patterns.tsv:        level<TAB>shell-pattern<TAB>reason
project_markers.tsv:      project_type<TAB>relative-file-or-directory
clipboard_providers.tsv:  name<TAB>command<TAB>arg1<TAB>arg2...
```

`risk_patterns.tsv` levels are `high`, `medium`, and `low`. The first matching
rule wins after whitespace is squeezed and the command is wrapped with one
leading and trailing space.

`local_commands.txt` lists command names allowed by `command_run` when the
selected execution backend is `local`. The local backend also requires a low
risk result and rejects redirection, command substitution, background jobs,
command-list separators, absolute paths, parent-directory paths, and selected
write-capable options. Pipelines are allowed only when every segment uses
configured command names.

</details>

## Prompts

Prompt templates are installed under `~/.config/lmline/prompts/`. Set
`LMLINE_PROMPT_DIR` to override templates selectively; missing files fall back
to the installed defaults.

Engine-appended safety rules, tool protocol rules, candidate limits, and byte
limits cannot be removed by prompt overrides.

<details>
<summary>Installed prompt template names</summary>

```text
generate.txt rewrite.txt fix.txt explain.txt clip.txt
system.generate.txt system.explain.txt system.clip.txt
explain_brief.txt explain_normal.txt explain_detailed.txt
```

</details>

## Privacy

The user line is always sent because it is the request being completed or
rewritten. Other user-environment context is controlled by settings.

Default context collection includes:

```text
shell/OS details      LMLINE_INCLUDE_SHELL_CONTEXT=1
current directory     LMLINE_INCLUDE_CWD_CONTEXT=1
Git root and branch   LMLINE_INCLUDE_GIT_CONTEXT=1
project type markers  LMLINE_INCLUDE_PROJECT_CONTEXT=1
cursor point          LMLINE_INCLUDE_EDITOR_CONTEXT=1
locale variables      LMLINE_INCLUDE_LOCALE_CONTEXT=1
suggested commands    LMLINE_INCLUDE_SUGGESTED_COMMANDS=1
tool descriptions     LMLINE_TOOL_MODE=auto and enabled LMLINE_TOOL_* flags
```

Default context collection does not read file contents, shell history, lmline
debug history, the full command inventory, current-directory file names, or the
clipboard. Tools can expose extra local facts only when enabled and only when
the model calls them. `file_excerpt` is disabled by default because it reads
bounded file content. `command_run` is disabled by default because it executes
a command through the selected backend and sends bounded stdout/stderr back to
the model. `Ctrl-x Ctrl-v` sends redacted clipboard text because that action is
explicitly about the clipboard. `Ctrl-x Ctrl-f` sends the captured stdout,
stderr, exit status, and execution backend from the command it runs.

<details>
<summary>Accuracy-oriented setup</summary>

```bash
lmline config set LMLINE_TOOL_MODE auto
lmline config set LMLINE_TOOL_COMMAND_EXISTS 1
lmline config set LMLINE_TOOL_COMMANDS 1
lmline config set LMLINE_TOOL_COMMAND_INFO 1
lmline config set LMLINE_TOOL_FILES 1
lmline config set LMLINE_TOOL_GIT_STATUS 1
lmline config set LMLINE_TOOL_FILE_EXCERPT 1
lmline config set LMLINE_TOOL_COMMAND_RUN 1
lmline config set LMLINE_EXEC_BACKEND auto
lmline config set LMLINE_INCLUDE_SHELL_CONTEXT 1
lmline config set LMLINE_INCLUDE_CWD_CONTEXT 1
lmline config set LMLINE_INCLUDE_GIT_CONTEXT 1
lmline config set LMLINE_INCLUDE_PROJECT_CONTEXT 1
lmline config set LMLINE_INCLUDE_EDITOR_CONTEXT 1
lmline config set LMLINE_INCLUDE_LOCALE_CONTEXT 1
lmline config set LMLINE_INCLUDE_SUGGESTED_COMMANDS 1
```

</details>

<details>
<summary>Most secure setup</summary>

```bash
lmline config set LMLINE_TOOL_MODE none
lmline config set LMLINE_TOOL_GIT_STATUS 0
lmline config set LMLINE_TOOL_FILE_EXCERPT 0
lmline config set LMLINE_TOOL_COMMAND_RUN 0
lmline config set LMLINE_EXEC_BACKEND off
lmline config set LMLINE_INCLUDE_SHELL_CONTEXT 0
lmline config set LMLINE_INCLUDE_CWD_CONTEXT 0
lmline config set LMLINE_INCLUDE_GIT_CONTEXT 0
lmline config set LMLINE_INCLUDE_PROJECT_CONTEXT 0
lmline config set LMLINE_INCLUDE_EDITOR_CONTEXT 0
lmline config set LMLINE_INCLUDE_LOCALE_CONTEXT 0
lmline config set LMLINE_INCLUDE_SUGGESTED_COMMANDS 0
lmline debug trace off
```

</details>

With the secure setup, the model receives the current input line, mode, response
language default, candidate limits, and no local tool access. Set
`LMLINE_RESPONSE_LOCALE` explicitly if you want a non-English response language
without sending locale environment variables.

`LMLINE_EXEC_BACKEND=auto` uses the configured microsandbox CLI when `msb` is
available; otherwise it uses the local backend. Set
`LMLINE_MICROSANDBOX_COMMAND` if the CLI is installed under another name or
path. lmline does not install microsandbox automatically. microsandbox is beta
software and requires Linux with KVM or macOS on Apple Silicon. `lmline sandbox
check` runs `msb --version` only.

API keys are passed to `curl` through `-H @file` header files created in a
temporary directory. They are not placed on the `curl` command line.

Trace files are disabled by default:

```bash
lmline debug trace on
lmline debug trace off
```

Trace files are written under `~/.config/lmline/traces/` and can contain
prompts, paths, provider responses, accepted/rejected candidates, tool output,
and captured output from `Ctrl-x Ctrl-f`.

## Advanced Settings

```bash
lmline config set LMLINE_ASYNC 1
lmline config set LMLINE_SELECTOR fzf
lmline config set LMLINE_STREAM 1
lmline config set LMLINE_CACHE_TTL 300
lmline config set LMLINE_CANDIDATE_COUNT 5
lmline config set LMLINE_TOOL_MODE auto
lmline config set LMLINE_TOOL_MODE text
lmline config set LMLINE_TOOL_MODE openai
lmline config set LMLINE_TOOL_MODE none
```

`LMLINE_ASYNC=1` makes the first generate key start a background request; press
the generate key again to insert the result when ready.

`LMLINE_SELECTOR` is Bash-only. It is split on whitespace and executed as a
command argv array when more than one candidate is available.

`LMLINE_STREAM=1` streams `explain` and `clip` responses. Tool rounds still run
between streamed provider responses.

`LMLINE_CACHE_TTL` caches `generate`, `rewrite`, and `explain`
responses under `~/.config/lmline/cache/`. `fix` and `clip` are not cached.

<details>
<summary>Tool modes and available tools</summary>

Tool mode values:

```text
auto    send OpenAI-compatible tool schemas and fall back to text tool requests
openai  send OpenAI-compatible tool schemas only
text    use text tool requests only
none    disable tools
off     alias for none
```

Available tools:

```text
command_exists  command -v for specific command names
command_info    command path, kind, type -a, and bounded version/help output
commands        local command-name search by fragment
files           local file-name search from find . -maxdepth 2
git_status      git --no-optional-locks status --short --branch,
                disabled by default
file_excerpt    bounded excerpt from one text file under the current directory,
                disabled by default
command_run     bounded command execution through LMLINE_EXEC_BACKEND,
                disabled by default
```

</details>

## Settings Reference

Use `lmline config defaults`, `lmline config effective`, and
`lmline config describe KEY` for the full setting catalog, current values, and
single-setting help. Detailed tables are grouped below.

- Path settings
- Provider and engine settings
- Interactive settings
- Context and tool settings
- Data-file settings

<details>
<summary>Path settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_CONFIG_DIR` | `~/.config/lmline` | config, installed support files, profiles, secrets, cache, traces |
| `LMLINE_BIN_DIR` | `~/.local/bin` | install target for the `lmline` symlink |
| `LMLINE_HISTORY_DIR` | `$LMLINE_CONFIG_DIR/history` | recorded suggestion log directory |
| `LMLINE_DEFAULTS_DIR` | installed defaults | packaged data-file defaults |
| `LMLINE_USER_RULES_DIR` | `$LMLINE_CONFIG_DIR` | user override directory for data files |

</details>

<details>
<summary>Provider and engine settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_BASE_URL` | empty | API base path used with the selected API format |
| `LMLINE_ACTIVE_ENDPOINT` | empty | endpoint name last selected by `lmline use` |
| `LMLINE_MODEL` | auto-discover | model ID; if unset, engine calls the configured model catalog except for `payload` |
| `LMLINE_API_FORMAT` | `chat` | `chat`, `responses`, or `messages` |
| `LMLINE_MODELS_URL` | `$LMLINE_BASE_URL/models` | model catalog URL used by `model refresh` and auto-discovery |
| `LMLINE_MODELS_JQ` | built-in | jq expression that emits candidate model items from the catalog response |
| `LMLINE_MODELS_PREFIX` | empty | keep only discovered model IDs with this prefix |
| `LMLINE_MODELS_INCLUDE` | empty | keep only discovered model candidates matching this extended regex |
| `LMLINE_MODELS_EXCLUDE` | empty | drop discovered model candidates matching this extended regex |
| `LMLINE_API_KEY_FILE` | empty | file containing the API key |
| `LMLINE_AUTH_HEADER` | `Authorization` | authentication header name |
| `LMLINE_AUTH_SCHEME` | `Bearer` | authentication scheme; empty means raw header value |
| `LMLINE_ENGINE_TIMEOUT` | `60` | seconds per provider request |
| `LMLINE_HTTP_RETRIES` | `1` | transient provider retries |
| `LMLINE_RETRY_DELAY` | `1` | seconds between retries |
| `LMLINE_CACHE_TTL` | `0` | response cache TTL in seconds |
| `LMLINE_STREAM` | `0` | stream `explain` and `clip` responses |
| `LMLINE_TEMPERATURE` | `0.2` | chat completion temperature |
| `LMLINE_MAX_TOKENS` | `1200` | max response tokens for command modes |
| `LMLINE_EXPLAIN_MAX_TOKENS` | `1200` | max response tokens for `explain` |
| `LMLINE_CLIP_MAX_TOKENS` | `1200` | max response tokens for `clip` |
| `LMLINE_EXPLAIN_DETAIL` | `normal` | `brief`, `normal`, or `detailed` |
| `LMLINE_EXPLAIN_MAX_OUTPUT_BYTES` | `65536` | displayed explanation byte limit |
| `LMLINE_CLIP_MAX_OUTPUT_BYTES` | `65536` | displayed clip response byte limit |
| `LMLINE_MAX_CANDIDATE_BYTES` | `4096` | candidate byte limit |
| `LMLINE_ENGINE` | installed engine | engine executable |
| `LMLINE_PROMPT_DIR` | installed prompts | prompt override directory |
| `LMLINE_PROMPT_VERSION` | `1` | prompt/context version marker used in request keys |
| `LMLINE_RESPONSE_LOCALE` | locale-derived when locale context is enabled | response language selector |
| `LMLINE_TRACE_DIR` | empty | trace output directory |

</details>

<details>
<summary>Interactive settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_CANDIDATE_COUNT` | `3` | requested candidate count, clamped to 1..10 |
| `LMLINE_ASYNC` | `0` | background generation |
| `LMLINE_BIND_KEYS` | `1` | bind keys when init file is sourced |
| `LMLINE_KEY_GENERATE` | `\C-x\C-g` | generate key binding |
| `LMLINE_KEY_REWRITE` | `\C-x\C-r` | rewrite key binding |
| `LMLINE_KEY_NEXT` | `\C-x\C-n` | next candidate key binding |
| `LMLINE_KEY_PREV` | `\C-x\C-p` | previous candidate key binding |
| `LMLINE_KEY_EXPLAIN` | `\C-x\C-e` | explain key binding |
| `LMLINE_KEY_FIX` | `\C-x\C-f` | fix key binding |
| `LMLINE_KEY_CLIP` | `\C-x\C-v` | clipboard key binding |
| `LMLINE_CLIPBOARD_PROVIDER` | `auto` | clipboard provider name |
| `LMLINE_CLIPBOARD_PROVIDERS_FILE` | installed defaults | provider TSV path |
| `LMLINE_CLIP_MAX_INPUT_BYTES` | `65536` | redacted clipboard input byte limit |
| `LMLINE_SELECTOR` | empty | Bash-only external candidate selector |
| `LMLINE_STATUS_MODE` | `inline` | `inline`, `transient`, `log`/`debug`, or `silent`/`none` |
| `LMLINE_SPINNER` | `1` | waiting animation |
| `LMLINE_SPINNER_INTERVAL` | `0.2` | spinner refresh interval |
| `LMLINE_PROGRESS` | `1` | engine progress lines |
| `LMLINE_PS0` | `🍋‍🟩 ` | lmline status prefix |
| `LMLINE_FIX_TIMEOUT` | `12` | seconds for fix command execution |
| `LMLINE_FIX_MAX_OUTPUT` | `12000` | stdout/stderr byte limit for fix |
| `LMLINE_FIX_ALLOW_MEDIUM` | `0` | allow medium-risk fix execution |
| `LMLINE_EXPERIMENTAL_DEFAULT_COMPLETION` | `0` | Bash default completion hook |
| `LMLINE_DEBUG` | `0` | verbose debug logging for Bash integration |

</details>

<details>
<summary>Context and tool settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_TOOL_MODE` | `auto` | `auto`, `openai`, `text`, or `none` |
| `LMLINE_TOOL_CHOICE` | `auto` | OpenAI-compatible `tool_choice` value |
| `LMLINE_TOOL_COMMAND_EXISTS` | `1` | enable `command_exists` |
| `LMLINE_TOOL_COMMANDS` | `1` | enable `commands` |
| `LMLINE_TOOL_COMMAND_INFO` | `1` | enable `command_info` |
| `LMLINE_TOOL_FILES` | `1` | enable `files` |
| `LMLINE_TOOL_GIT_STATUS` | `0` | enable `git_status` |
| `LMLINE_TOOL_FILE_EXCERPT` | `0` | enable `file_excerpt` |
| `LMLINE_TOOL_COMMAND_RUN` | `0` | enable `command_run` |
| `LMLINE_EXEC_BACKEND` | `auto` | `auto`, `local`, `microsandbox`, or `off` |
| `LMLINE_MICROSANDBOX_COMMAND` | `msb` | microsandbox CLI command name or path |
| `LMLINE_MICROSANDBOX_NAME` | empty | persistent sandbox name; empty uses ephemeral `msb run` |
| `LMLINE_MICROSANDBOX_IMAGE` | `debian` | image for ephemeral runs and `sandbox setup` |
| `LMLINE_MICROSANDBOX_MEMORY` | `512M` | memory for ephemeral runs and setup sandboxes |
| `LMLINE_MICROSANDBOX_CPUS` | `1` | vCPU count for ephemeral runs and setup sandboxes |
| `LMLINE_MICROSANDBOX_SETUP_TIMEOUT` | `30` | seconds for setup-time CLI operations |
| `LMLINE_MICROSANDBOX_WORKDIR` | `/workspace` | guest workdir for `sandbox setup` |
| `LMLINE_MICROSANDBOX_WORKSPACE_MODE` | `readonly` | `readonly`, `writable`, or `none` for project bind mount |
| `LMLINE_MICROSANDBOX_REQUIRED_COMMANDS` | empty | extra space-separated commands checked by `sandbox setup` |
| `LMLINE_MAX_TOOL_ROUNDS` | `10` | maximum tool-use rounds |
| `LMLINE_MAX_TOOL_CALLS_PER_ROUND` | `20` | per-round tool call limit |
| `LMLINE_TOOL_RESULT_SUMMARIZE` | `0` | summarize long multi-round tool history |
| `LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS` | `12000` | summarization threshold |
| `LMLINE_TOOL_RESULT_SUMMARY_MAX_TOKENS` | `300` | summarization token limit |
| `LMLINE_INCLUDE_SHELL_CONTEXT` | `1` | include Bash version, `OSTYPE`, and `uname` |
| `LMLINE_INCLUDE_CWD_CONTEXT` | `1` | include current directory |
| `LMLINE_INCLUDE_GIT_CONTEXT` | `1` | include Git root and branch |
| `LMLINE_INCLUDE_PROJECT_CONTEXT` | `1` | include project type inferred from markers |
| `LMLINE_INCLUDE_EDITOR_CONTEXT` | `1` | include cursor point |
| `LMLINE_INCLUDE_LOCALE_CONTEXT` | `1` | include locale variables for response language |
| `LMLINE_INCLUDE_SUGGESTED_COMMANDS` | `1` | include configured suggested commands |
| `LMLINE_TOOL_COMMANDS_LIMIT` | `120` | `commands` result limit |
| `LMLINE_TOOL_FILES_LIMIT` | `80` | `files` result limit |
| `LMLINE_TOOL_GIT_STATUS_LINES` | `80` | `git_status` result line limit |
| `LMLINE_TOOL_FILE_EXCERPT_LINES` | `80` | `file_excerpt` result line limit |
| `LMLINE_TOOL_COMMAND_RUN_TIMEOUT` | `3` | seconds per `command_run` call |
| `LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT` | `12000` | stdout/stderr byte limit for `command_run` |
| `LMLINE_TOOL_COMMAND_RUN_MAX_RISK` | `medium` | highest risk level allowed for sandbox-backed `command_run` |
| `LMLINE_MAX_PIPELINE_COMMANDS` | `30` | command words summarized from a pipeline |
| `LMLINE_TOOL_INFO_LINES` | `40` | lines kept per command-info block |
| `LMLINE_TOOL_INFO_LINE_BYTES` | `240` | bytes kept per command-info line |
| `LMLINE_TOOL_INFO_TIMEOUT` | `2` | seconds per command-info probe |

</details>

<details>
<summary>Data-file settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_SUGGESTED_COMMANDS_FILE` | user override or installed default | suggested command list |
| `LMLINE_FILE_SEARCH_EXCLUDES_FILE` | user override or installed default | `files` tool exclude list |
| `LMLINE_SHELL_SYNTAX_WORDS_FILE` | user override or installed default | words ignored by command availability validation |
| `LMLINE_COMMAND_PREFIX_WORDS_FILE` | user override or installed default | command prefixes ignored before command extraction |
| `LMLINE_RISK_PATTERNS_FILE` | user override or installed default | candidate risk rules |
| `LMLINE_PROJECT_MARKERS_FILE` | user override or installed default | project type markers |
| `LMLINE_LOCAL_COMMANDS_FILE` | user override or installed default | local backend allowlist for `command_run` |
| `LMLINE_DOCTOR_REQUIRED_COMMANDS_FILE` | user override or installed default | required command list for `doctor` |
| `LMLINE_DOCTOR_OPTIONAL_COMMANDS_FILE` | user override or installed default | optional command list for `doctor` |

</details>

## Development Check

```bash
./tests/run.sh
bash tests/test_features.sh
```

`./tests/run.sh` runs every `tests/test_*.sh` file and reports all failures.
