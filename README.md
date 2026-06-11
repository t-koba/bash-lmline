# lmline

`lmline` is an interactive shell helper that turns the current prompt line into a language-model-generated command candidate. It inserts text into the line buffer only; it never presses Enter.

The included engine targets OpenAI-compatible chat completion APIs. That covers local servers and many cloud gateways.

## Install

```bash
./install.sh
```

The primary integration targets Bash Readline through `bind -x` and `READLINE_LINE`. A minimal zsh ZLE integration is also available in `init.zsh`; it reuses the Bash context/policy code through a `bash -c` bridge.

## Dependencies

Runtime dependencies are intentionally small.

Required for the interactive integration:

```text
bash 4.2+ with Readline bind -x, or zsh with ZLE
```

Required only for the bundled OpenAI-compatible engine:

```text
curl 7.55+ (API keys are passed via `-H @file`, not on the command line)
jq
```

Optional features use these commands when available:

```text
find        file-name context collection
git         repository root, branch, and project-local config from Git root
timeout     bounded command help collection and fix-command execution
sha256sum   request keys; falls back to shasum, then cksum
shasum
cksum
sed/awk/sort/uniq
            context formatting and CLI display helpers
pbpaste/wl-paste/xclip/xsel/powershell.exe/tmux
            clipboard reading for `lmline clip` and `Ctrl-x Ctrl-v`
```

Install/test helpers additionally use common POSIX tools such as `install`, `ln`, `chmod`, `mktemp`, and `rm`.

The scripts avoid hard-coding GNU-only or BSD-only command flags for their own core behavior. For generated commands, lmline asks the model to match the local OS and can expose `command_info` so the model sees the local command kind, path, and bounded version/help output before answering or fixing GNU/BSD-sensitive commands.

## Editable Local Lists

Most concrete command lists and policy patterns are data files, not code. The packaged defaults live under `lmline/defaults/` in this repository and are installed under `~/.config/lmline/defaults/`.

To override a default for one user, create a file with the same name directly under `~/.config/lmline/`:

```text
~/.config/lmline/suggested_commands.txt
~/.config/lmline/file_search_excludes.txt
~/.config/lmline/shell_syntax_words.txt
~/.config/lmline/command_prefix_words.txt
~/.config/lmline/risk_patterns.tsv
~/.config/lmline/project_markers.tsv
~/.config/lmline/clipboard_providers.tsv
~/.config/lmline/doctor_required_commands.txt
~/.config/lmline/doctor_optional_commands.txt
```

You can also point to a specific file:

```bash
lmline config set LMLINE_SUGGESTED_COMMANDS_FILE /path/to/suggested_commands.txt
lmline config set LMLINE_FILE_SEARCH_EXCLUDES_FILE /path/to/file_search_excludes.txt
lmline config set LMLINE_SHELL_SYNTAX_WORDS_FILE /path/to/shell_syntax_words.txt
lmline config set LMLINE_COMMAND_PREFIX_WORDS_FILE /path/to/command_prefix_words.txt
lmline config set LMLINE_RISK_PATTERNS_FILE /path/to/risk_patterns.tsv
lmline config set LMLINE_PROJECT_MARKERS_FILE /path/to/project_markers.tsv
lmline config set LMLINE_CLIPBOARD_PROVIDERS_FILE /path/to/clipboard_providers.tsv
lmline config set LMLINE_DOCTOR_REQUIRED_COMMANDS_FILE /path/to/doctor_required_commands.txt
lmline config set LMLINE_DOCTOR_OPTIONAL_COMMANDS_FILE /path/to/doctor_optional_commands.txt
```

`suggested_commands.txt` is optional. If it is empty, missing, or disabled with `LMLINE_INCLUDE_SUGGESTED_COMMANDS=0`, lmline omits the `suggested_commands` context section and still works through normal prompting and optional tool calls.

`risk_patterns.tsv` uses tab-separated fields:

```text
level<TAB>shell-pattern<TAB>reason
```

The first matching rule wins. `level` is `high`, `medium`, or `low`.
Before matching, the command is normalized: whitespace is squeezed to single
spaces and the whole line is wrapped in one leading and one trailing space.
A single pattern like `* dd *` therefore matches `dd if=...` at line start,
`... | dd of=...` mid-pipeline, and a bare `dd`; start-anchored duplicate
rows are not needed.

`project_markers.tsv` uses:

```text
project_type<TAB>relative-file-or-directory
```

`clipboard_providers.tsv` uses:

```text
name<TAB>command<TAB>arg1<TAB>arg2...
```

`lmline clip` executes the selected provider as an argv array, not through shell evaluation. The default `auto` provider tries installed readers such as `pbpaste`, `wl-paste`, `xclip`, `xsel`, `powershell.exe`, and `tmux` in the configured order.

`install.sh` detects an installed clipboard reader and writes `LMLINE_CLIPBOARD_PROVIDER` when it is not already configured. On macOS this normally selects `macos`, which uses `pbpaste`. On Linux it prefers `wayland` (`wl-paste`), then `xclip`, `xsel`, WSL PowerShell clipboard access, and `tmux`. Existing clipboard provider settings are preserved.

If an explicit `LMLINE_*_FILE` path is set and cannot be read, lmline fails with an error instead of silently using defaults.

## Prompts

All prompt text the engine sends is plain data under `lmline/prompts/` (installed to `~/.config/lmline/prompts/`):

```text
generate.txt continue.txt rewrite.txt fix.txt explain.txt clip.txt   # per-mode task prompts
system.generate.txt   # system rules for generate/continue/rewrite/fix
system.explain.txt    # system rules for explain
system.clip.txt       # system rules for clip
explain_brief.txt explain_normal.txt explain_detailed.txt   # LMLINE_EXPLAIN_DETAIL levels
```

Set `LMLINE_PROMPT_DIR` to override selectively: the engine looks in that directory first and falls back to the installed defaults per file, so you can override just one file. Safety rules (untrusted-data handling, the tool-call protocol, and the tool round budget) and dynamic values (candidate count, byte limits) are always appended by the engine code and cannot be removed through prompt overrides.

Temporary Bash trial after install:

```bash
bash --rcfile "$HOME/.config/lmline/init.bash" -i
```

Temporary Bash trial directly from a repository checkout:

```bash
bash --rcfile "$PWD/lmline/init.bash" -i
```

Temporary zsh trial after install:

```zsh
source "$HOME/.config/lmline/init.zsh"
```

Temporary zsh trial directly from a repository checkout:

```zsh
source "$PWD/lmline/init.zsh"
```

The zsh integration enables `interactivecomments` so `# request text` behaves like a prompt comment instead of being executed as a command if you press Enter by mistake.

For permanent Bash use, add this to `~/.bashrc`:

```bash
if [[ $- == *i* ]]; then
  source "$HOME/.config/lmline/init.bash"
fi
```

For permanent zsh use, add this to `~/.zshrc`:

```zsh
source "$HOME/.config/lmline/init.zsh"
```

## Provider Profiles

The recommended workflow is to register one or more endpoints, register or import their models, and switch with `lmline use`. This keeps provider selection discoverable through shell completion instead of requiring model IDs to be typed from memory.

Each endpoint URL is an OpenAI-compatible API base path. lmline appends `/chat/completions` for chat requests and `/models` for model discovery. Examples:

| Provider | Endpoint URL |
| --- | --- |
| LM Studio | `http://127.0.0.1:1234/v1` |
| Ollama | `http://127.0.0.1:11434/v1` |
| OpenAI | `https://api.openai.com/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Gemini OpenAI-compatible API | `https://generativelanguage.googleapis.com/v1beta/openai` |
| Sakura AI Engine | `https://api.ai.sakura.ad.jp/v1` |

The endpoint name is your local alias. Use descriptive names such as `lmstudio`, `ollama`, `openai`, `openrouter`, `gemini`, or `sakura`; `local` is fine as a personal alias when there is only one local server.

LM Studio example, usually without authentication unless you configured tokens in LM Studio:

```bash
lmline endpoint add lmstudio http://127.0.0.1:1234/v1 --tool-mode auto
lmline model refresh lmstudio
lmline use lmstudio <model-id>
```

If you already know the loaded model ID, or model listing is disabled by the server configuration, register it manually:

```bash
lmline model add lmstudio <model-id>
lmline use lmstudio <model-id>
```

Ollama example, usually without authentication:

```bash
lmline endpoint add ollama http://127.0.0.1:11434/v1 --tool-mode auto
lmline model refresh ollama
lmline use ollama <model-id>
```

OpenRouter example:

```bash
lmline endpoint add openrouter https://openrouter.ai/api/v1 --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret openrouter
lmline model refresh openrouter
lmline use openrouter openai/gpt-4.1-mini
```

Gemini OpenAI-compatible example:

```bash
lmline endpoint add gemini https://generativelanguage.googleapis.com/v1beta/openai --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret gemini
lmline model refresh gemini
lmline use gemini gemini-2.5-flash
```

OpenAI example:

```bash
lmline endpoint add openai https://api.openai.com/v1 --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret openai
lmline model refresh openai
lmline use openai gpt-4.1-mini
```

Sakura AI Engine example:

```bash
lmline endpoint add sakura https://api.ai.sakura.ad.jp/v1 --auth-header Authorization --auth-scheme Bearer --tool-mode auto
lmline endpoint set-secret sakura
lmline model add sakura gpt-oss-120b
lmline use sakura gpt-oss-120b
```

Sakura AI Engine uses the account token issued in the Sakura Cloud control panel as a Bearer token. Its documentation lists chat models such as `gpt-oss-120b`, `Qwen3-Coder-30B-A3B-Instruct`, `Qwen3-Coder-480B-A35B-Instruct-FP8`, and `llm-jp-3.1-8x13b-instruct4`. If `/models` is available for your token, `lmline model refresh sakura` can import model IDs; otherwise register the model you want with `lmline model add`.

Registered endpoint data is stored in `~/.config/lmline/endpoints.tsv`; registered models are stored in `~/.config/lmline/models.tsv`. Secrets are endpoint-scoped and stored as `0600` files under `~/.config/lmline/secrets/`; the TSV stores only the secret file path. Endpoint and model names cannot contain whitespace, tabs, or control characters.

`model refresh ENDPOINT` is the only model-discovery command. It calls the endpoint's `/models` path with that endpoint's auth settings and merges returned model IDs into `models.tsv`. Many OpenAI-compatible providers expose model listing through this path when the server/API key permits it. If a provider does not expose `/models`, use `lmline model add ENDPOINT MODEL`. Shell completion and `lmline use` only read registered local TSV data and do not contact the network.

Per-model values override endpoint values; empty model values fall back to the endpoint:

```bash
lmline endpoint add lmstudio http://127.0.0.1:1234/v1 --temperature 0.2 --max-tokens 500 --tool-mode auto
lmline model add lmstudio <model-id> --temperature 0.1
```

When exactly one model is registered for an endpoint, the model argument can
be omitted:

```bash
lmline use lmstudio
```

Removing profiles:

```bash
lmline model remove lmstudio <model-id>
lmline endpoint remove lmstudio                # also removes its models and secret
lmline endpoint remove lmstudio --keep-secret  # keep the stored API key file
```

Useful profile commands:

```bash
lmline endpoint list
lmline model list
lmline model list lmstudio
lmline current
lmline complete endpoints
lmline complete models lmstudio
```

Bash and zsh completion use `lmline complete ...`, so `lmline use <TAB>` shows registered endpoints and `lmline use lmstudio <TAB>` shows models registered under `lmstudio`.

The active selection is written to `~/.config/lmline/settings.bash` as ordinary `LMLINE_*` settings. The engine reads active settings, project-local config, and environment variables.

You can also bypass persistent config with environment variables:

```bash
export LMLINE_BASE_URL=http://127.0.0.1:1234/v1
export LMLINE_MODEL=<model-id>
export LMLINE_API_KEY_FILE=~/.config/lmline/secrets/openai-api-key.secret
```

If `LMLINE_MODEL` is unset, the engine tries to use the first model returned by the configured endpoint's `/models` path. `LMLINE_BASE_URL` must be set directly or by `lmline use ENDPOINT MODEL`.

The bundled engine waits up to 60 seconds for provider responses by default. The timeout applies to each provider request independently, including each tool-use round:

```bash
lmline config set LMLINE_ENGINE_TIMEOUT 120
```

Transient provider failures (HTTP 429/502/503/504 and curl errors) are retried automatically:

```bash
lmline config set LMLINE_HTTP_RETRIES 1   # default; 0 disables retries
lmline config set LMLINE_RETRY_DELAY 1    # seconds between attempts
```

For endpoints that expect the raw API key in a custom header (no `Bearer` scheme), set an empty auth scheme:

```bash
lmline endpoint add myapi https://api.example/v1 --auth-header X-Api-Key --auth-scheme ''
# or directly:
lmline config set LMLINE_AUTH_SCHEME ''
```

## Keys

| Key | Action |
| --- | --- |
| `Ctrl-x Ctrl-g` | Generate or continue from the current line |
| `Ctrl-x Ctrl-r` | Rewrite the current line |
| `Ctrl-x Ctrl-n` | Next candidate |
| `Ctrl-x Ctrl-p` | Previous candidate |
| `Ctrl-x Ctrl-e` | Explain the current candidate or line, including local risk/command context and model explanation |
| `Ctrl-x Ctrl-f` | Execute the current line once, capture stdout/stderr/status, and ask the model for a fix |
| `Ctrl-x Ctrl-v` | Ask the model about current clipboard text |

Key bindings are centralized as config variables:

```text
LMLINE_KEY_GENERATE=\C-x\C-g
LMLINE_KEY_REWRITE=\C-x\C-r
LMLINE_KEY_NEXT=\C-x\C-n
LMLINE_KEY_PREV=\C-x\C-p
LMLINE_KEY_EXPLAIN=\C-x\C-e
LMLINE_KEY_FIX=\C-x\C-f
LMLINE_KEY_CLIP=\C-x\C-v
```

Bash example:

```bash
lmline config set LMLINE_KEY_GENERATE '\C-g'
source ~/.config/lmline/init.bash
```

zsh uses zsh key notation:

```zsh
lmline config set LMLINE_KEY_GENERATE '^G'
source ~/.config/lmline/init.zsh
```

To disable automatic key binding and bind manually:

```bash
lmline config set LMLINE_BIND_KEYS 0
source ~/.config/lmline/init.bash
bind -x '"\C-g": __lmline_generate_widget'
```

The engine validates generated commands with `bash -n` and annotates every candidate with a risk level from `risk_patterns.tsv` (see `docs/engine-protocol.md`). Candidates matching `high` patterns are inserted as comments prefixed with `# REVIEW REQUIRED:`.

## Advanced UX

Async generation:

```bash
lmline config set LMLINE_ASYNC 1
```

With async enabled, the first `Ctrl-x Ctrl-g` starts generation in the background and returns immediately. Press `Ctrl-x Ctrl-g` again to insert the pending result when ready. Bash and zsh both default to synchronous generation, so the candidate is inserted by the same key operation when the engine returns.

External selector integration:

```bash
lmline config set LMLINE_SELECTOR fzf
```

In the Bash integration, when multiple candidates are available, they are piped to the selector and the selected line is inserted. The selector is executed as a command with optional whitespace-separated arguments; shell syntax such as pipes, redirects, and command substitution is not evaluated. Without a selector, Bash prints one compact status line after generation, such as `3 candidates; m=openai/gpt-4.1-mini; tok=120/35/155; tools=command-info; t=4s` where `tok` means input/output/total tokens and `t` is elapsed response time. Long model names are shortened for display to keep the line near 80 columns. Next/previous keys cycle candidates without adding more status lines. The zsh integration uses ZLE messages for the same candidate-count status.

Streaming display for `Ctrl-x Ctrl-e` (explain) and `Ctrl-x Ctrl-v` / `lmline clip`:

```bash
lmline config set LMLINE_STREAM 1
```

With streaming on, explanation and clipboard answers are printed line by line as the provider sends them (SSE). Streaming works together with tool use: native streamed `tool_calls` and text-protocol `TOOL` requests are collected mid-stream, the tools run locally (progress appears as usual), and the next round streams again until the final answer. `<think>` blocks from reasoning models are suppressed line by line. Token counts come from `stream_options.include_usage` when the provider supports it (lmline retries once without it otherwise), and the output byte limits (`LMLINE_EXPLAIN_MAX_OUTPUT_BYTES`, `LMLINE_CLIP_MAX_OUTPUT_BYTES`) apply to streamed output with a trailing `explanation-truncated` / `clip-output-truncated` marker. If a provider cannot stream at all, lmline falls back to a buffered request automatically with the conversation state intact.

Response cache:

```bash
lmline config set LMLINE_CACHE_TTL 300
```

With a TTL above 0 (seconds), generate/continue/rewrite/explain responses are cached under `~/.config/lmline/cache/` (mode 0700) keyed by the request line, directory, model, and settings. Re-running the same request within the TTL replays the cached candidates instantly and shows `cached` in the status line. `fix` and `clip` are never cached because their inputs include captured command output or clipboard text. Expired entries are pruned opportunistically; `0` (default) disables caching.

Candidate count:

```bash
lmline config set LMLINE_CANDIDATE_COUNT 5
```

The default limit is 3. The model may return fewer when there is only one useful command, but lmline asks for distinct alternatives when they are meaningfully different.

Project-local settings:

```bash
lmline config project-set LMLINE_ASYNC 1
lmline config project-unset LMLINE_ASYNC
lmline config project-get
```

This writes `./.lmline.bash`. Both `init.bash` and the bundled engine read project config from the Git root or current directory. Project config is parsed as `export LMLINE_NAME='value'` assignments only; it is not sourced as shell code.

Experimental default completion is available but off by default so Tab remains normal:

```bash
lmline config set LMLINE_EXPERIMENTAL_DEFAULT_COMPLETION 1
```

Status display defaults to an inline message that is overwritten and cleared instead of leaving history in the terminal. `LMLINE_PS0` is the shared prefix for lmline status output and defaults to `🍋‍🟩 `:

```bash
lmline config set LMLINE_PS0 '🍋‍🟩 '
```

For debugging:

```bash
lmline debug on
source ~/.config/lmline/init.bash
```

To inspect the exact provider interaction, enable trace files:

```bash
lmline debug trace on
```

This saves request JSON, response JSON, extracted text, accepted candidates, rejected candidates, and retry/tool payloads under `~/.config/lmline/traces`. These files may contain your prompt, local paths, file names, provider responses, captured command output from `Ctrl-x Ctrl-f`, and tool outputs, so leave tracing off unless you are debugging.

Return to clean inline status:

```bash
lmline debug off
lmline debug trace off
source ~/.config/lmline/init.bash
```

You can also set it manually:

```bash
lmline config set LMLINE_STATUS_MODE inline   # default; progress is overwritten, failures remain readable
lmline config set LMLINE_STATUS_MODE transient # progress and failures are cleared
lmline config set LMLINE_STATUS_MODE log      # leave log lines
lmline config set LMLINE_STATUS_MODE silent   # show nothing
lmline config set LMLINE_SPINNER 0            # disable the waiting animation
```

## CLI

```bash
lmline doctor
lmline doctor --check-api
lmline context '# list files'
lmline commands awk
lmline payload generate '# list files'
lmline clip 'このエラーの原因と次の確認手順を教えて'
lmline clip --status
lmline clip --providers
lmline clip --use macos
lmline clip --provider tmux 'この tmux buffer の出力を説明して'
lmline config get
lmline endpoint add lmstudio http://127.0.0.1:1234/v1
lmline endpoint list
lmline endpoint set-secret openai
lmline endpoint remove lmstudio
lmline model add lmstudio <model-id>
lmline model refresh lmstudio
lmline model list lmstudio
lmline model remove lmstudio <model-id>
lmline use lmstudio <model-id>
lmline use lmstudio
lmline current
lmline config project-set LMLINE_ASYNC 1
lmline config project-unset LMLINE_ASYNC
lmline risk 'rm -rf build'
lmline help 'find . -name "*.json" -print0 | xargs -0 jq -r ".user.id"'
lmline debug bindings
lmline debug trace on
lmline history show
lmline history tendencies
lmline explain 'find . -name "*.json" -print0 | xargs -0 jq -r ".user.id"'
```

## Privacy Defaults

Context collection sends shell/OS details, current directory, Git root/branch, project type, available tool descriptions when tool use is enabled, and a compact `suggested_commands` section only when configured. It does not read file contents, shell history, lmline debug history, the full command inventory, current-directory file names, or the clipboard by default.

`lmline clip` and `Ctrl-x Ctrl-v` are explicit clipboard actions. They read the current clipboard through the configured provider, redact common token/secret patterns, truncate the text to `LMLINE_CLIP_MAX_INPUT_BYTES`, and send it as untrusted pasted text. The command prints which clipboard provider was used before showing the model response.

Clipboard provider commands:

```bash
lmline clip --status       # selected provider
lmline clip --providers    # configured providers and availability
lmline clip --use macos    # persist selection
lmline clip --use auto     # return to automatic selection
lmline clip --provider tmux 'question'  # one request with a specific provider
```

To inspect what would be sent before using a provider:

```bash
lmline context '# your request'
lmline command-exists awk jq
lmline command-info date sed awk
lmline commands awk
lmline payload generate '# your request'
```

`payload` prints the JSON request body only; it does not contact the provider and does not include API keys. `doctor --check-api` is the command that performs a provider connectivity check; it calls the configured endpoint's `/models` path and uses the configured authentication header when an API key is configured.
When suggested commands are enabled, the prompt includes that compact configured list, not the full local command inventory or current-directory file list. Tool use defaults to `auto`: it tries provider-native OpenAI-compatible `tool_calls` when accepted, and also accepts provider-neutral text tool requests. If a provider rejects the OpenAI tool schema, lmline retries without the schema and continues with text tool requests.

```bash
lmline config set LMLINE_TOOL_MODE auto   # default; OpenAI tool_calls when accepted, plus text tool requests
lmline config set LMLINE_TOOL_MODE text   # provider-neutral text tool protocol only
lmline config set LMLINE_TOOL_MODE openai # OpenAI-compatible tool_calls only
lmline config set LMLINE_TOOL_MODE none   # disable tool use
```

When enabled, the engine can expose local `command_exists`, `command_info`, `commands`, and `files` tools to the model for generate, rewrite, fix, and explain requests. `command_exists` is preferred when the model only wants to verify a specific command name; `command_info` is for implementation details such as GNU/BSD/macOS option differences; `commands` is only for discovery when the command name is unknown; `files` is used only when file-name context is needed. `auto` is the recommended default. Use `text` for providers that mishandle OpenAI tool schemas, and use `openai` only when the provider reliably returns OpenAI-compatible `tool_calls`. During interactive requests, tool calls are shown in the progress display with the same short names used in the final status: `command-exists`=`command_exists`, `command-info`=`command_info`, `command-search`=`commands`, `file-search`=`files`; for example `tool command-info (openai, round 1/10)`. After the response, generate/rewrite and explain displays include response model, token counts, tools, and elapsed time as `m=<model>; tok=<input>/<output>/<total>; tools=<short-names>; t=<seconds>` when the provider returns usage metadata. This is status metadata only; tool results remain untrusted reference data and are not inserted into the command line. Tool choice applies only when OpenAI-compatible tool schemas are sent; for testing a tool-capable provider you can force a tool call:

```bash
lmline config set LMLINE_TOOL_CHOICE required
```

Individual tools can be disabled explicitly. All are enabled by default:

```bash
lmline config set LMLINE_TOOL_COMMAND_EXISTS 0
lmline config set LMLINE_TOOL_COMMANDS 0
lmline config set LMLINE_TOOL_COMMAND_INFO 0
lmline config set LMLINE_TOOL_FILES 0
```

Tool use can continue for multiple rounds. Defaults:

```bash
lmline config set LMLINE_MAX_TOOL_ROUNDS 10
lmline config set LMLINE_MAX_TOOL_CALLS_PER_ROUND 20
```

The current round, maximum rounds, and per-round tool-call limit are included in the prompt so the model can plan its tool use within the budget.

By default, raw tool results are kept in the same provider conversation and are not mechanically truncated. For long multi-round tool sessions, lmline can ask the configured model in a separate request to summarize earlier tool results before continuing:

```bash
lmline config set LMLINE_TOOL_RESULT_SUMMARIZE 1
lmline config set LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS 12000
lmline config set LMLINE_TOOL_RESULT_SUMMARY_MAX_TOKENS 300
```

This is off by default. Even when enabled, summarization runs only after multiple tool rounds and only when accumulated tool output exceeds `LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS`. On local servers that allow only one concurrent prediction, especially some LM Studio MLX setups, leave it disabled until the server handles nested or closely chained prediction requests reliably.

Tool arguments are intentionally narrow:

- `command_exists commands="<command names>"` runs `command -v` for each command name and returns `name<TAB>found<TAB>path` or `name<TAB>missing`.
- `command_info commands="<command names>"` returns local command path, shell kind, `type -a`, and bounded version probe output selected for the local OS. Version/help text is sanitized, line/byte-limited, wrapped as untrusted data, and intended only for portability-sensitive commands and fixes.
- `commands query="<command-name fragment>"` searches local command names collected from `compgen` with a short command-name fragment. It is not for natural-language requests.
- `files query="<file-name fragment>"` searches file names from `find . -maxdepth 2` after applying `file_search_excludes.txt`. It does not read file contents.

`LMLINE_MAX_PIPELINE_COMMANDS` controls how many command words are summarized from a pipeline for explain/help and command-info paths. The default is 30.

## Configuration Reference

All persistent settings are written as `export LMLINE_NAME='value'` entries in `~/.config/lmline/settings.bash` by `lmline config set`. Project settings use the same format in `./.lmline.bash`.

Provider and engine settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `LMLINE_BASE_URL` | empty | OpenAI-compatible API base path; lmline appends `/chat/completions` and `/models` |
| `LMLINE_ACTIVE_ENDPOINT` | empty | endpoint name last selected by `lmline use`; used by `lmline current`/`doctor` matching |
| `LMLINE_MODEL` | auto-discover | model id; if unset, engine calls the endpoint's `/models` path except in `payload` dry-run |
| `LMLINE_API_KEY_FILE` | empty | file containing the API key; endpoint secrets write this automatically |
| `LMLINE_AUTH_HEADER` | `Authorization` | authentication header name |
| `LMLINE_AUTH_SCHEME` | `Bearer` | authentication scheme; set empty for raw header values |
| `LMLINE_ENGINE_TIMEOUT` | `60` | seconds per provider request |
| `LMLINE_HTTP_RETRIES` | `1` | retries for transient provider failures (429/502/503/504, curl errors); `0` disables |
| `LMLINE_RETRY_DELAY` | `1` | seconds between retry attempts |
| `LMLINE_CACHE_TTL` | `0` | response cache lifetime in seconds for generate/continue/rewrite/explain; `0` disables |
| `LMLINE_STREAM` | `0` | stream explain/clip responses (SSE), including through tool rounds |
| `LMLINE_TEMPERATURE` | `0.2` | chat completion temperature |
| `LMLINE_MAX_TOKENS` | `500` | maximum response tokens for command-generation modes |
| `LMLINE_EXPLAIN_MAX_TOKENS` | `1200` | maximum response tokens for explanations; safe to raise because explanation output is displayed, not inserted |
| `LMLINE_CLIP_MAX_TOKENS` | `1200` | maximum response tokens for clipboard analysis |
| `LMLINE_EXPLAIN_DETAIL` | `normal` | explanation granularity for `Ctrl-x Ctrl-e`: `brief`, `normal`, or `detailed`; the model still scales length to command complexity |
| `LMLINE_EXPLAIN_MAX_OUTPUT_BYTES` | `65536` | maximum explanation text displayed by `Ctrl-x Ctrl-e`; longer explanations are truncated with `explanation-truncated` |
| `LMLINE_CLIP_MAX_OUTPUT_BYTES` | `65536` | maximum clipboard-analysis text displayed; longer responses are truncated with `clip-output-truncated` |
| `LMLINE_MAX_CANDIDATE_BYTES` | `4096` | maximum inserted candidate line length; longer candidates are truncated and shown with `candidate-truncated`; increase for terminals/shells that comfortably handle longer one-liners |
| `LMLINE_ENGINE` | installed engine path | replacement engine executable; must implement `docs/engine-protocol.md` |
| `LMLINE_PROMPT_DIR` | installed prompts | prompt template directory; files missing there fall back to the installed defaults |

Interactive settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `LMLINE_CANDIDATE_COUNT` | `3` | requested candidate count, clamped by the engine to at most 10 |
| `LMLINE_ASYNC` | `0` | background generation mode |
| `LMLINE_BIND_KEYS` | `1` | automatically bind keys on source |
| `LMLINE_KEY_GENERATE` etc. | see `lmline keys` | key binding strings |
| `LMLINE_CLIPBOARD_PROVIDER` | `auto` | clipboard provider name from `clipboard_providers.tsv`, or `auto` |
| `LMLINE_CLIPBOARD_PROVIDERS_FILE` | installed defaults | provider TSV used by `lmline clip` |
| `LMLINE_CLIP_MAX_INPUT_BYTES` | `65536` | maximum redacted clipboard bytes sent to the model |
| `LMLINE_SELECTOR` | empty | Bash-only external selector for multiple candidates |
| `LMLINE_STATUS_MODE` | `inline` | `inline`, `transient`, `log`, or `silent` |
| `LMLINE_SPINNER` | `1` | waiting animation on/off |
| `LMLINE_SPINNER_INTERVAL` | `0.2` | spinner refresh interval |
| `LMLINE_PROGRESS` | `1` | emit/show tool-use progress events while the engine is running |
| `LMLINE_PS0` | `🍋‍🟩 ` | prefix for lmline status output |
| `LMLINE_FIX_TIMEOUT` | `12` | seconds for `Ctrl-x Ctrl-f` capture execution |
| `LMLINE_FIX_MAX_OUTPUT` | `12000` | captured stdout/stderr byte budget for fix |
| `LMLINE_FIX_ALLOW_MEDIUM` | `0` | allow medium-risk fix capture execution |

Context and tool settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `LMLINE_TOOL_MODE` | `auto` | `auto`, `text`, `openai`, or `none` |
| `LMLINE_TOOL_CHOICE` | `auto` | OpenAI-compatible `tool_choice` value |
| `LMLINE_TOOL_COMMAND_EXISTS` | `1` | enable `command_exists` tool |
| `LMLINE_TOOL_COMMANDS` | `1` | enable `commands` tool |
| `LMLINE_TOOL_COMMAND_INFO` | `1` | enable `command_info` tool |
| `LMLINE_TOOL_FILES` | `1` | enable `files` tool |
| `LMLINE_MAX_TOOL_ROUNDS` | `10` | maximum tool-use rounds |
| `LMLINE_MAX_TOOL_CALLS_PER_ROUND` | `20` | maximum tool calls accepted per round |
| `LMLINE_TOOL_RESULT_SUMMARIZE` | `0` | enable separate-request tool-result summarization |
| `LMLINE_TOOL_RESULT_SUMMARY_MIN_CHARS` | `12000` | accumulated tool-output threshold before summarization |
| `LMLINE_TOOL_RESULT_SUMMARY_MAX_TOKENS` | `300` | maximum tokens for tool-result summaries |
| `LMLINE_INCLUDE_SUGGESTED_COMMANDS` | `1` | include configured suggested commands |
| `LMLINE_TOOL_COMMANDS_LIMIT` | `120` | command names returned by the `commands` tool |
| `LMLINE_TOOL_FILES_LIMIT` | `80` | file names returned by the `files` tool |
| `LMLINE_MAX_PIPELINE_COMMANDS` | `30` | command words summarized from a pipeline |
| `LMLINE_TOOL_INFO_LINES` | `40` | lines kept per command-info block |
| `LMLINE_TOOL_INFO_LINE_BYTES` | `240` | bytes kept per command-info line |
| `LMLINE_TOOL_INFO_TIMEOUT` | `2` | seconds per command-info probe |

## Development Check

```bash
./tests/run.sh        # run every tests/test_*.sh and report all failing files
bash tests/test_features.sh   # run a single area directly
```

Tests are split by area under `tests/` (`test_policy.sh`, `test_cli.sh`, `test_engine.sh`, `test_features.sh`, `test_widgets_bash.sh`, `test_widgets_zsh.sh`, `test_pty.sh`, `test_clip.sh`, `test_fix.sh`, `test_smoke.sh`) and share the harness in `tests/lib.sh`. The runner executes every file even when one fails and exits non-zero if any failed. If an OpenAI-compatible local server is running at `LMLINE_BASE_URL`, `test_smoke.sh` also performs a best-effort engine smoke test.
