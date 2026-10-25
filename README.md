# lmline

`lmline` is a Bash/zsh line editor helper. It asks an OpenAI-compatible chat
completion endpoint for command candidates and inserts the selected candidate
into the current shell line buffer. It does not press Enter: generated
candidates are inserted without executing them. It never executes a candidate
on its own; the paths that run a command are `Ctrl-x Ctrl-f` (fix), which
explicitly re-runs the current line once through `LMLINE_EXEC_BACKEND` to
capture failure evidence (`LMLINE_EXEC_BACKEND=off` disables it), the opt-in
`command_run` tool, and `lmline sandbox run`, all of which the user invokes or
enables and all of which are risk-gated (see Candidate Handling and
SECURITY.md). One more path can run a program without the user invoking it, but only when explicitly opted in with `LMLINE_TOOL_COMMAND_INFO=1`: the `command_info` tool then probes an external program the model names with the fixed flag `--version` under a short timeout (see SECURITY.md).

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

Standalone CLI completions (optional; the init scripts already load them, so
this only matters for shells that do not source the full integration):

```bash
# bash
source "$HOME/.config/lmline/completions/lmline.bash"
```

```zsh
# zsh: add before compinit in ~/.zshrc
fpath+=("$HOME/.config/lmline/completions")
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

## ChatGPT subscription authentication

lmline can spend a ChatGPT Plus or Pro subscription instead of a metered API
key, using OpenAI's documented "Sign in with ChatGPT" token sharing flow for
open-source and locally hosted apps. The subscription path is a separate
authentication mode: it never falls back to an API key, and it never sends
the subscription token to a host other than the OpenAI API.

The sign-in needs Node.js (the client is a Node script without npm
dependencies) and a browser:

```bash
lmline chatgpt login
```

The client prints an `authorize_url` line before it waits for the callback, so
a headless machine can open it by hand. The sign-in registers the
application once; later sign-ins reuse that registration.

```bash
lmline chatgpt status    # account, plan usage, scopes, expiry; never a token
lmline chatgpt refresh   # new access token; the refresh token rotates
lmline chatgpt reauth    # new authorization for the same account
lmline chatgpt logout    # revoke the refresh token, then clear the local tokens
```

A refresh whose answer states no granted scope drops the plan grant, because
the grant is then unproven. The client keeps the session but refuses to hand
out a token, so the sign-in has to be repeated.

Register the endpoint with the subscription path and select it:

```bash
lmline endpoint add openai-plan https://api.openai.com/v1 --auth-mode chatgpt
lmline model add openai-plan MODEL
lmline use openai-plan MODEL
```

The plan route is account scoped: the provider accepts only the models the
signed-in account can use. lmline reads the endpoint's model catalog
(`$LMLINE_BASE_URL/models` by default) with the plan token when no model is
selected, and uses the model id each entry carries. That a real plan serves
the account's own models at that URL is not proven offline, like the rest of
the subscription route. A model can also be registered by hand, and the
plan route needs the Responses format:

```bash
lmline model add openai-plan MODEL --api-format responses
```

The model must exist on the signed-in account; a model id that the account
does not carry is refused by the provider, and that refusal is not proven
offline.

`lmline current` and `lmline doctor` show the active authentication mode.
To go back to API-key billing, set the endpoint's mode back with
`lmline endpoint add openai-plan https://api.openai.com/v1 --auth-mode api-key`
and select it again.

The account catalog is read with the plan token, so it travels under the
same host rule as a request: a plan endpoint on a host the route does not
allow is refused before the token is fetched and before any request is
made, and a catalog URL on such a host is refused the same way whenever the
catalog is read.

The credentials live in `$LMLINE_CONFIG_DIR/chatgpt/credentials.json`, mode
`0600` inside an owner-only directory, and the stable host identifier in
`$LMLINE_CONFIG_DIR/chatgpt/host-id`. The client refuses a credential file
that other users can read and says how to fix it. `status` prints no token,
and only the internal token command prints one, on stdout.

On this route the request follows the contract of the subscription API: the
Responses format, `store: false`, `stream: true`, the instructions as
`instructions`, and no sampling or account fields. The engine does not repeat
the request on its own, because a repeated request can spend the plan: the
route answers once per exchange, and the local tools are off there, because a
tool round would be another request that spends the plan.

The subscription token is sent only to the OpenAI API, and only over
`https`. A loopback proxy (`http://127.0.0.1:PORT/v1`,
`http://localhost:PORT/v1`, or `http://[::1]:PORT/v1`) is accepted, because
its traffic stays on the machine; any other host, a cleartext base to the
OpenAI API, a base URL without an explicit scheme, and a base URL that embeds
credentials are refused before a request is sent.

## Native web search

Native web search is a provider-side capability: the model asks the provider
to retrieve pages, the provider performs the network access, and the answer
comes back with the search events and the cited URLs. lmline never fetches
those pages itself.

It is off by default and needs the Responses API format:

```bash
lmline config set LMLINE_API_FORMAT responses
lmline config set LMLINE_WEB_SEARCH 1
```

The search events and the cited URLs are reported on the stderr side channel
as `lmline-search:` and `lmline-citation:` lines, never inside the candidate
text. The provider bills the search calls, so a rejected request is reported
with the provider's reason instead of being repeated, and the provider is
asked for at most one new search per exchange: a later tool round reuses the
earlier results.

[docs/capabilities.md](docs/capabilities.md) lists every supported,
unsupported, and allowed-but-unverified combination of authentication mode,
endpoint, API format, model, and search.

## GitHub Copilot line editing

The rewrite key (`Ctrl-x Ctrl-r`), generate (`Ctrl-x Ctrl-g`), and fix
(`Ctrl-x Ctrl-f`) can optionally use the official GitHub Copilot Language
Server's `textDocument/inlineCompletion`. Generate completes at the cursor and
preserves the typed prefix byte-for-byte; rewrite and fix complete the whole
line. The normal OpenAI-compatible engine remains the default and
Copilot adds no dependency until it is enabled.

Install the pinned Language Server package, sign in, and select a backend:

```bash
lmline copilot setup
lmline copilot login
lmline config set LMLINE_REWRITE_BACKEND copilot
lmline config set LMLINE_GENERATE_BACKEND copilot   # optional
lmline config set LMLINE_FIX_BACKEND copilot        # optional
```

Fix mode still runs the failed command locally and passes the captured
stderr/stdout to Copilot as buffer context, so the suggestion has the same
execution evidence the engine gets. Generate is best at completing a command
you are typing; Copilot has no rich shell context, so empty-line or
`# comment`-intent generation is weaker than the engine's.

`lmline config set` is picked up by the next widget invocation: the shell
re-reads `settings.bash` when it changed on disk, so no shell restart is
needed. Each mode keeps its own backend — rewrite, generate, and fix default
to the engine until their `LMLINE_*_BACKEND` is set to `copilot` — and any
mode left on `engine` still needs a configured endpoint and model.

Copilot requires Node.js 20.8+ and npm. The package is installed under
`$LMLINE_CONFIG_DIR/copilot`; `install.sh` never downloads it. A per-user
daemon is started on the first Copilot command and shared by Bash and zsh.

All three modes use the language server's `textDocument/inlineCompletion`
(completion engine, not chat): generate completes at the cursor and keeps the
typed prefix byte-for-byte; rewrite and fix complete the whole line and use
the model's replacement. Plan completion limits apply: Copilot Free includes
2,000 completions per month and Copilot Student includes unlimited completions
(see [usage-based billing for individuals](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals)),
but completion only *completes*: it returns nothing when
the line is already complete, and fix suggestions depend on the model seeing
a fixable line. lmline prints a diagnostic (`no candidates from Copilot`)
when the server returns nothing.

`lmline copilot login` prints the device code immediately, then opens the
browser once; if you are already signed in, it says so and opens nothing.
Run `lmline copilot status` afterwards to confirm `status=OK` before editing.

```bash
lmline copilot status
lmline copilot update          # explicit update to latest
lmline copilot update 1.498.0  # explicit version
lmline copilot restart
lmline copilot logout
lmline copilot remove
```

If editing fails, the current line is left untouched and lmline does not
silently send it to the normal engine. Run `lmline copilot status`, inspect
`$LMLINE_CONFIG_DIR/copilot/runtime/daemon.log`, or restart the daemon. Restore
the original backend with `lmline config set LMLINE_REWRITE_BACKEND engine`.

After updating lmline, restart the Copilot daemon and start a new shell: the
daemon is a long-lived process that keeps running the code it was started
with, and the shell loads the widget functions at startup. Run
`lmline copilot restart` after updating, then open a new shell.

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
| OpenCode Console (OpenAI) | `https://opencode.ai/inference/openai/v1` |
| OpenCode Go | See the compatibility note below; `lmline` does not meet Go’s full client guidance. |

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
<summary>OpenCode Go compatibility note</summary>

OpenCode Go documents routes such as
`https://opencode.ai/inference/go/openai/v1/responses`. Its client guidance
also asks for a stable per-conversation `x-opencode-session` header and a
client-specific user agent. `lmline` can configure the route and API format,
but does not currently expose those per-request headers, so it does not meet
that full Go client guidance. The Console OpenAI endpoints shown below do not
require those Go-specific headers.

</details>

<details>
<summary>Command example: OpenCode Console (OpenAI Responses)</summary>

```bash
lmline endpoint add opencode-console https://opencode.ai/inference/openai/v1 \
  --auth-header Authorization --auth-scheme Bearer
lmline endpoint set-secret opencode-console
lmline model add opencode-console gpt-5.5 --api-format responses
lmline use opencode-console gpt-5.5
```

OpenCode Console's OpenAI Responses route is
`https://opencode.ai/inference/openai/v1/responses`; `lmline` appends that
path when the model uses `--api-format responses`. OpenAI Chat Completions
models use the same base URL with `--api-format chat` (the default). Use the
model's direct API ID, not OpenCode's config prefix such as `opencode/`.

The current Console model list (`https://opencode.ai/inference/v1/models`)
returns model IDs without API-family metadata, so `model refresh` defaults
those entries to `chat` and can overwrite a manually selected Responses
format. Add Responses models explicitly with `--api-format responses` unless
the catalog provides format metadata. This example covers OpenAI Chat/Responses
routes; OpenCode's other API families use different base paths and must match
the format configured in `lmline`. See OpenCode's
[Console models](https://opencode.ai/v2/docs/console/models/) and
[Inference API](https://opencode.ai/v2/docs/console/api/inference/) docs.

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

`model refresh` mirrors the endpoint catalog: it adds new models, updates the
stored API format for imported models, preserves per-model temperature,
max tokens, and tool mode, and removes that endpoint's rows whose IDs are no
longer served. Removal is decided against the unfiltered catalog IDs (only
`--models-jq` applied), so a manually added model that is filtered out but
still advertised is kept. Other endpoints are untouched and `models.tsv`
keeps its schema. Even when filters exclude every import candidate, refresh
still reconciles existing rows against the raw catalog; an empty or invalid raw
catalog instead fails without changing the stored models. The summary line
reports the final stored model count, added/updated/removed counts, and removed
names; when the active selection points at a removed model it warns with the
next `lmline use` command but leaves configuration unchanged. A failed fetch,
parse, or merge keeps the existing `models.tsv`.

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

Project files (entries 3 and 4) are only loaded when the user enables
`LMLINE_PROJECT_CONFIG` (`lmline config set LMLINE_PROJECT_CONFIG 1`) in
their own settings or environment. It defaults to `0`, so a cloned
repository cannot change the engine, provider, or tool settings on its own,
and a project file cannot enable it by itself.

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

Candidates are ordered for experienced command-line use. The first candidate is
the recommended practical one-liner: correctness, safety, local tool/OS fit,
and idiomatic composition take priority over raw character count. Later
candidates are intended to offer a real tradeoff—such as a different tool,
greater portability, stronger handling of unusual file names, or a more
readable pipeline—not cosmetic variations of the same command.

Use generate (`Ctrl-x Ctrl-g`) when an existing prefix must remain byte-for-byte
unchanged and only needs a suffix. Use rewrite (`Ctrl-x Ctrl-r`) when lmline may
requote, restructure, or replace the whole command. For example, generate can
complete `find . |`, while rewrite can replace a fragile file-processing loop
with an equivalent pipeline. The first candidate is inserted immediately; use
next/previous to compare the alternatives without executing any of them.

The engine filters candidates before printing them:

- one line only
- no control characters
- valid syntax for the target shell (`bash -n` or `zsh -f -n`)
- no environment-assignment-only command segment
- no direct directory operands for simple file readers such as `cat`
- command words available locally, except configured shell syntax words and
  command prefixes (for zsh, its builtins count); matching interactive-shell
  function names are recognized at top-level command positions
- command words containing `/` available only as literal paths to regular executable files (filesystem `-f`/`-x` metadata only, symlinks followed). The supported subset is a whitespace-free word using ASCII letters, digits, `_/:.+@-`, optionally enclosed in one whole pair of single or double quotes. Dynamic, escaped, concatenated and other opaque command spellings fail closed without expansion. Relative slash paths after a possible directory change fail closed even with an all-absolute inherited `PATH`; absolute paths stay independent of cwd. Direct `PATH=...` command prefixes use the same file check
- deduplicated
- truncated to `LMLINE_MAX_CANDIDATE_BYTES` when needed

Only caller-function names cross the validator boundary; candidate text is
parsed but never executed, and function bodies are never transferred. A literal
nested `bash -c` or `zsh -f -c` script uses the child shell's lookup rather than
the parent's full function list: unexported parent functions do not authorize
child commands, while Bash exports normally inherited by a child Bash are
modeled. `command` and external `env` do not dispatch shell functions, so their
operands need a real builtin or PATH fallback.

For candidate-defined functions, availability checking tracks direct literal
`unset -f NAME...` (Bash/Zsh) and `unfunction NAME...` (Zsh), where each `NAME` is
an unquoted identifier (`[a-zA-Z_][a-zA-Z0-9_]*`). Removal forgets every matching
binding, preserves unrelated names, and permits later explicit redefinition.
`unset -v NAME...` only affects variables. Unsupported removal operands/options,
quoting, redirections, and command-prefix wrappers fail closed. Removals in
conditional branches, loop bodies/headers, and non-direct pipeline/and-or positions
also fail closed rather than re-trusting a saved function binding. A function
whose entire body is supported literal removals is summarized only for its
immediately adjacent bare direct call at top level; nested, wrapped, argument-
bearing, redirected, non-adjacent, or mixed-effect calls fail closed. A remover
terminated by a backgrounding operator does not invalidate the parent shell's
availability. Ordinary braces share availability; subshells, function-definition
bodies, and background braces keep their existing isolated snapshots. These are
syntax-only rules, not a general interpretation of arbitrary function-call
effects.

Availability checking also recognizes a plain `eval` command with exactly one
single-quoted literal argument, for example `eval 'printf ok'`. Its contents are
parsed with the target shell's syntax-only mode and checked for available command
words; validation never executes the text or its substitutions. Dynamic arguments
and unsupported forms (including double quotes, concatenation, multiple arguments,
options, wrappers, and redirections) retain their existing availability behavior.
This is conservative recognition, not a complete shell interpreter or sandbox.

Availability checking also recognizes a plain `trap` command with exactly one
single-quoted literal action followed by signal specification(s), for example
`trap 'printf ok' EXIT`. Its contents are parsed with the target shell's
syntax-only mode and checked for available command words; validation never
executes the text or its substitutions. Dynamic actions and unsupported forms
(including double quotes, concatenation, missing signals, options, wrappers, and
non-command positions) retain their existing availability behavior. This is
conservative recognition, not a complete shell interpreter or sandbox.

Availability checking also recognizes direct `bash -c '...'` and `zsh -f -c '...'`
invocations with exactly one single-quoted literal script argument. Bash may
also receive `-e`, `-u`, `-v`, and `-x` separately or clustered before `-c`,
for example `bash -e -u -vx -c 'printf ok'`. The contents are parsed with the
invoked shell's syntax-only mode and checked with that shell's command
vocabulary; validation never executes the text or its substitutions. Dynamic
arguments and unsupported forms (including double quotes, concatenation, extra
operands, unallowlisted options, wrappers, paths, and redirections)
retain their existing availability behavior. This is conservative recognition,
not a complete shell interpreter or sandbox.

Each accepted candidate is classified with the configured `risk_patterns.tsv`
and structural pipe-to-shell, interactive history expansion, unresolved
variable, capped brace, and recursive remove recognition. High-risk candidates are inserted as comments prefixed with
`# REVIEW REQUIRED:`. Medium-risk candidates are inserted with a warning.
Low-risk candidates are inserted directly. Structural levels are
configuration (`LMLINE_RISK_PIPED_SHELL_LEVEL` default `high`,
`LMLINE_RISK_HISTORY_EXPANSION_LEVEL` default `high`,
`LMLINE_RISK_UNRESOLVED_VAR_LEVEL` default `medium`,
`LMLINE_RISK_BRACE_CAPPED_LEVEL` default `medium`,
`LMLINE_RISK_RECURSIVE_REMOVE_LEVEL` default `high`); the highest applicable
structural level wins. With the shipped defaults the highest level across
patterns and structural wins, so a generic medium rule never shadows a
structural high. A replacement `risk_patterns.tsv` overrides shipped
patterns and structural defaults: a matching rule wins and structural
fallbacks apply only when no rule matched.

A recursive remove is recognised by the word in the position a command occupies
and by the flags written with it, so the family reads the same way in every
spelling: `rm -rf`, `rm -fr`, `rm --force --recursive`, a remove a program that
runs another program carries (`env -i rm -fr build`, `timeout 5 rm -fr build`,
`busybox rm -rf /`), a remove behind the operand a program names for itself
(`su root rm -rf /`, `chroot /path rm -rf /`), and a remove written in a shell
command string (`bash -c "rm -fr build"`, `bash -c"rm -fr build"`) are one
command. A word that merely carries the name of a remove is not the family:
`ls rm -r` and `grep rm -rf file` are not removes. A program that removes files
by a subcommand of its own is that program, so `git rm -r dir` is named by the
pattern file. Only the remove family is read this way, so an ordinary recursive
copy or search stays as the pattern file states it.

The same rule decides whether a pipeline reaches a shell: the shell the piped
input reaches is the command the segment runs, so `find . | xargs sh` is a piped
shell execution while `find . | xargs grep sh` is not, because the command
`xargs` runs is `grep`.

History recognition checks the original candidate before quote stripping or
ANSI-C decoding. It flags potentially active conventional `!` event references
in unquoted and double-quoted text, such as `!!`, `!123`, `!-2`, `!echo`,
`!?text?`, `!#`, word selectors (`!$`, `!^`, `!*`, `!:0`), modifiers
(`!!:s/old/new/`), and zsh's `!{echo}`. Ordinary single-quoted literals
(`echo '!!'`), ANSI-C single quotes, and backslash-escaped event characters
(`echo \!\!` or `echo "\!\!"`) do not trigger this structural check. A bare
`!` before whitespace, `=`, or end of input, and `!` immediately before a
closing double quote, are not event references. All structural settings accept
`low`, `medium`, or `high`; invalid or empty values use the documented default.

This is a lexical risk check, not a shell/history parser: other unescaped
`!` prefixes are conservatively flagged, even if the event does not exist.
It assumes conventional default history characters and interactive Bash/zsh
options. Custom `histchars`, disabled history expansion, Bash POSIX mode,
quick `^old^new^` substitution, and full parsing of nested shell constructs
are outside its supported scope; nested quoting can be classified
conservatively. lmline neither reads/expands shell history nor changes history
settings or `!` in candidate text. Only the existing high-risk review-comment
prefix changes the presented line.

The first inserted candidate shows the candidate count and model metadata.
Cycling with `Ctrl-x Ctrl-n` / `Ctrl-x Ctrl-p` shows the current position
(for example `2/3`) so moving through candidates never feels like a no-op;
truncated candidates and the preserved original (rewrite mode) are flagged in
the same indicator.

`Ctrl-x Ctrl-f` is the only key binding that executes the current line; the other execution paths are the opt-in `command_run` tool, `lmline sandbox run`, and the opt-in `command_info` version probe (see intro and SECURITY.md).
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
lmline chatgpt login|status|refresh|reauth|logout
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

After setup, persist the printed `next_config` commands in the project config (and enable `LMLINE_PROJECT_CONFIG` so project files are loaded).
Then `LMLINE_EXEC_BACKEND=microsandbox` uses `msb exec` in that named sandbox
instead of ephemeral `msb run`. Ephemeral images must contain `/bin/sh`:
lmline overrides the image entrypoint with `/bin/sh` and passes the command
via `-c`, even when the image defines a non-shell entrypoint.

</details>

## Clipboard

Clipboard providers are configured in `clipboard_providers.tsv`:

```text
name<TAB>command<TAB>arg1<TAB>arg2...
```

`lmline clip` and `Ctrl-x Ctrl-v` read the selected provider as an argv array,
not through shell evaluation. The default `auto` provider uses the first
available configured provider; when every provider fails, each failure is
reported on its own line with a pointer to `lmline clip --providers`.

Clipboard text is redacted before it is sent, then condensed to
`LMLINE_CLIP_MAX_INPUT_BYTES` (see Output Condensation below), and marked as
untrusted pasted text. Redaction masks these patterns:

```text
VAR_TOKEN/SECRET/PASSWORD/KEY=value and key: value assignments (spaces around =/: allowed)
Authorization: Bearer <token> headers
sk-... OpenAI-style API keys (after the first 12 characters)
sk_live_/sk_test_/rk_live_/rk_test_... Stripe keys (body redacted, prefix kept; pk_live_ publishable keys are left alone)
ghp_/gho_/ghu_/ghs_/ghr_/github_pat_... GitHub tokens (body redacted, prefix kept)
AKIA/ASIA/ABIA/ACCA/A3T... AWS access key IDs (body redacted, prefix kept)
xox*-/xapp-... Slack tokens (body redacted, prefix kept)
glpat-... GitLab personal access tokens (body redacted, prefix kept)
AIza... Google API keys (body redacted, prefix kept)
PEM private-key blocks (whole block redacted, body included)
```

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
shell_words.txt
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
lmline config set LMLINE_SHELL_WORDS_FILE /path/to/shell_words.txt
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
leading and trailing space. Structural fallbacks use
`LMLINE_RISK_PIPED_SHELL_LEVEL` (default `high`),
`LMLINE_RISK_HISTORY_EXPANSION_LEVEL` (default `high`),
`LMLINE_RISK_UNRESOLVED_VAR_LEVEL` (default `medium`),
`LMLINE_RISK_BRACE_CAPPED_LEVEL` (default `medium`), and
`LMLINE_RISK_RECURSIVE_REMOVE_LEVEL` (default `high`), highest wins; unknown
or empty levels fall back to their defaults. With the shipped defaults the
highest level across patterns and structural wins. A replacement file
overrides shipped patterns and structural defaults: a matching rule wins
and structural fallbacks apply only when no rule matched.

`local_commands.txt` lists command names allowed by `command_run` when the
selected execution backend is `local`. The local backend also requires a low
risk result and rejects redirection, command substitution, background jobs,
command-list separators, absolute paths, parent-directory paths, and selected
write-capable options. Pipelines are allowed only when every segment's first
word is a configured command name; leading environment assignments and wrappers
are not skipped to find an allowlisted command.

Local command operands support literal unquoted text, single/double-quoted
text (including spaces and empty arguments), and adjacent quote fragments.
Path and action checks use the resulting words after quote removal, including
values of assignment-style operands such as `--file='relative name'`.
Literal backslash escapes follow Bash's unquoted and double-quoted rules;
single-quoted backslashes remain literal. Unquoted glob characters (`*`, `?`,
`[`), unquoted `#`, dollar signs, unquoted tildes, and tilde-prefixed decoded
words/assignment values are refused rather than expanded or interpreted as
comments. The shell operators, substitution syntax, and braces listed above
remain refused even inside quotes. These are lexical restrictions, not
filesystem isolation: local commands still run in the host environment (for example, a relative
symlink can refer outside the working directory). Use microsandbox when
isolation is needed.

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
the model calls them. `command_info` is disabled by default because it runs a
bounded `--version` probe for a model-named program and returns its output to
the model. `file_excerpt` is disabled by default because it reads bounded file
content. `command_run` is disabled by default because it executes a command
through the selected backend and sends bounded stdout/stderr back to the model.
`git_status`, `command_info`, `file_excerpt`, and `command_run` require exact
`1` to enable; unset, empty, and any other value leave them disabled.
`Ctrl-x Ctrl-v` sends redacted clipboard text because that action is
explicitly about the clipboard. `Ctrl-x Ctrl-f` sends the captured stdout,
stderr, exit status, and execution backend from the command it runs.

Native web search is provider-side: the provider retrieves the pages, and
the retrieved content is untrusted data that the request marks as such. The
provider bills those search calls. A ChatGPT subscription sign-in keeps its
credential in an owner-only file and sends it only to the OpenAI API; it
never mixes with the API-key path.

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
lmline config set LMLINE_TOOL_COMMAND_INFO 0
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
lmline config set LMLINE_STORE 0
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
software and requires Linux with KVM, macOS on Apple Silicon, or Windows 10+
with WHP (preview; see [Windows troubleshooting](https://docs.microsandbox.dev/troubleshooting/windows)).
`lmline sandbox check` runs `msb --version` only.

API keys are passed to `curl` through `-H @file` header files created in a
temporary directory. They are not placed on the `curl` command line.
Provider requests ignore implicit curl configuration files, so only the
configured provider receives them; proxy and CA environment variables still
apply.

Provider-side request storage is opt-out on OpenAI APIs: an unset `store` keeps the request server-side (Responses stored by default; new-account Chat stored by default). lmline fails closed and always sends an explicit value: `store: false` by default (`LMLINE_STORE=0`), `store: true` when `LMLINE_STORE=1`. The `messages` format has no `store` field. Providers that reject the `store` field with HTTP 400 fail by default so an explicit `store: false` is never silently dropped; set `LMLINE_STORE_FALLBACK=1` to allow one retry without `store` for providers where omission is acceptable. Only errors indicating the `store` field itself was rejected trigger the fallback. Allowing storage does not change answers; it only changes provider retention.

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
the same key again to insert the result when ready. While the request runs the
hint shows elapsed seconds, and a generation that outlives
`LMLINE_ENGINE_TIMEOUT` (+5s) is killed with a timeout message.
`LMLINE_ASYNC_NOTIFY=1` additionally prints a one-line "suggestion ready"
notice at the next prompt (via `PROMPT_COMMAND` / `precmd`).

`LMLINE_SELECTOR` is Bash-only. It is split on whitespace and executed as a
command argv array when more than one candidate is available.

`LMLINE_STREAM=1` streams `explain` and `clip` responses on the `chat` format. Tool rounds still run
between streamed provider responses. Other formats use buffered requests.

`LMLINE_CACHE_TTL` caches `generate`, `rewrite`, and `explain` responses under
`~/.config/lmline/cache/` (mode 0700). The default is 600 seconds, so
repeating the same request in the same directory answers instantly without an
API call; set `LMLINE_CACHE_TTL=0` to disable caching. `fix` and `clip` are
not cached. Cache keys include the mode, line, directory, model, prompt
version, and the effective request payload (resolved prompts and
sampling/output settings), so prompt upgrades and configuration changes such
as the response language never serve stale entries.

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
command_info    command path, kind, type -a, and bounded version/help output,
                disabled by default
commands        local command-name search by fragment
files           local file-name search from find . -maxdepth 2
git_status      git --no-optional-locks status --short --branch,
                disabled by default
file_excerpt    bounded excerpt from one text file under the current directory,
                disabled by default
command_run     bounded command execution through LMLINE_EXEC_BACKEND,
                disabled by default
```

All local tool results are untrusted reference data, including command names,
filenames, repository status, and paths. The engine marks these results in
bounded delimiter blocks; the markers do not execute or validate their contents.

</details>

## Output Condensation

Captured output that exceeds its byte budget (fix-mode stdout/stderr,
`command_run` tool results, clipboard text, long command help) is condensed
instead of being cut at an arbitrary byte:

- the head and the tail of the output are both kept
- consecutive duplicate lines fold into one line annotated `(repeated Nx)`
- lines matching `condense_priority_patterns.txt` (errors, warnings,
  tracebacks) are rescued from the omitted middle
- cuts land on line and UTF-8 boundaries only

An omitted region is marked with a line like
`...[omitted 120 lines, ~9000 bytes]...`. These markers (and `(repeated Nx)`)
are inserted locally; they are not part of the original output. Budgets are
controlled by the existing `LMLINE_FIX_MAX_OUTPUT`,
`LMLINE_TOOL_COMMAND_RUN_MAX_OUTPUT`, and `LMLINE_CLIP_MAX_INPUT_BYTES`
settings, plus `LMLINE_CONDENSE_LINE_BYTES` (per-line cap),
`LMLINE_CONDENSE_RESCUE_LINES` (max rescued lines), and
`LMLINE_CONDENSE_PATTERNS_FILE` (custom priority patterns). A custom pattern
file replaces the packaged `lmline/defaults/condense_priority_patterns.txt`
list; it is not merged with it. Patterns are extended regular expressions,
one per line, with blank and `#` comment lines ignored. An explicit empty file
therefore disables priority-line rescue. If an explicitly configured file is
missing or unreadable, condensation fails with a diagnostic rather than
silently sending uncondensed output.

## Concurrency and Locking

Mutating CLI commands (`endpoint`, `model`, `use`, `config set/unset`,
`debug on/off/trace`) take a lock on `~/.config/lmline/.lmline.lock` so
concurrent `lmline` invocations from different terminals cannot lose each
other's writes. The lock is a directory (`mkdir` is atomic on POSIX and
portable to macOS, which lacks `flock`). `lmline doctor` warns about stale
locks. Locks are never reclaimed automatically: checking a PID then removing
the directory can delete a successor's lock. After stopping all writers, remove
a stale `.lmline.lock` directory manually under the configured config directory.
`LMLINE_LOCK_TIMEOUT` (default 5s) bounds the wait; `LMLINE_NO_LOCK=1`
disables locking for filesystems where `mkdir` atomicity is unreliable
(some NFS mounts).

## Debugging

```bash
lmline debug on           # verbose logging; status lines go to stderr
lmline debug trace on     # write full request/response traces
lmline doctor --check-api # dependency, profile, lock, and connectivity checks
```

With tracing on, every engine call writes the exact payloads, responses,
streamed text, and accepted/rejected candidates under
`~/.config/lmline/traces/` (mode 0700). Error messages stay short on screen
but include recovery hints (for example `lmline endpoint set-secret` on
HTTP 401) and point at the trace for the full provider response.

The `lmline-meta:` line emitted by the engine includes machine-readable
counters — token usage, tools used, elapsed time, plus `rejected=N` and
`retried=1` when local validation rejected candidates — which makes prompt
or model changes measurable from logs (`LMLINE_STATUS_MODE=log`).

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
| `LMLINE_API_FORMAT` | `chat` | `chat`, `responses`, or `messages`; native local tools (`openai`/`auto`) work on `chat` and `responses`, streaming is chat-only, so `responses`/`messages` run buffered requests (`messages` without native tool calls) |
| `LMLINE_MODELS_URL` | `$LMLINE_BASE_URL/models` | model catalog URL used by `model refresh` and auto-discovery |
| `LMLINE_MODELS_JQ` | built-in | jq expression that emits candidate model items from the catalog response |
| `LMLINE_MODELS_PREFIX` | empty | keep only discovered model IDs with this prefix |
| `LMLINE_MODELS_INCLUDE` | empty | keep only discovered model candidates matching this extended regex |
| `LMLINE_MODELS_EXCLUDE` | empty | drop discovered model candidates matching this extended regex |
| `LMLINE_API_KEY_FILE` | empty | file containing the API key |
| `LMLINE_AUTH_HEADER` | `Authorization` | authentication header name |
| `LMLINE_AUTH_SCHEME` | `Bearer` | authentication scheme; empty means raw header value |
| `LMLINE_AUTH_MODE` | `api-key` | authentication path: `api-key` reads the endpoint secret, `chatgpt` uses a ChatGPT subscription sign-in and the Responses format on the OpenAI API |
| `LMLINE_CHATGPT_CLIENT` | the installed client | the ChatGPT client executable; every path of the subscription route uses it, so the sign-in, the account catalog and the requests belong to the same client |
| `LMLINE_CHATGPT_LOCK_WAIT_MS` | `180000` | milliseconds a ChatGPT command waits for the credential lock; it is raised to the stale threshold plus 30 s when that is larger, so a waiter can always reclaim an abandoned lock |
| `LMLINE_CHATGPT_LOCK_STALE_MS` | `60000` | milliseconds before an abandoned ChatGPT credential lock is reclaimed; the wait budget is raised to at least this value plus 30 s, so a waiter can always reclaim it |
| `LMLINE_CHATGPT_CREDENTIALS_FILE` | `$LMLINE_CONFIG_DIR/chatgpt/credentials.json` | credential file the ChatGPT client reads and writes |
| `LMLINE_CHATGPT_HOST_ID_FILE` | `$LMLINE_CONFIG_DIR/chatgpt/host-id` | host identifier file the ChatGPT client reads and writes |
| `LMLINE_CHATGPT_AUTH_URL` | `https://auth.openai.com` | authorization endpoint of the ChatGPT sign-in |
| `LMLINE_CHATGPT_API_URL` | `https://api.openai.com/v1` | API endpoint the ChatGPT client sends requests to |
| `LMLINE_CHATGPT_AGENT_NAME` | `lmline` | client name the ChatGPT sign-in identifies itself with |
| `LMLINE_CHATGPT_CALLBACK_PORT` | `1455` | local port the ChatGPT sign-in callback listens on |
| `LMLINE_CHATGPT_TIMEOUT` | `300` | seconds a ChatGPT request may take |
| `LMLINE_CHATGPT_BROWSER_COMMAND` | empty | command that opens the ChatGPT authorization page |
| `LMLINE_CHATGPT_NO_BROWSER` | `0` | skip the browser during the ChatGPT sign-in (`0` opens it, `1` skips it) |
| `LMLINE_WEB_SEARCH` | `0` | native provider web search (`0` disables, `1` enables; Responses format only) |
| `LMLINE_ENGINE_TIMEOUT` | `60` | seconds per provider request |
| `LMLINE_HTTP_RETRIES` | `1` | transient provider retries |
| `LMLINE_RETRY_DELAY` | `1` | seconds between retries |
| `LMLINE_CACHE_TTL` | `600` | response cache TTL in seconds (0 disables) |
| `LMLINE_STREAM` | `0` | stream `explain` and `clip` responses |
| `LMLINE_STORE` | `0` | request provider-side storage (`0` sends `store: false`, `1` sends `store: true`; `chat` and `responses` only) |
| `LMLINE_STORE_FALLBACK` | `0` | allow one retry without store field when provider rejects it (`0` fails the request, `1` omits store and retries once) |
| `LMLINE_TEMPERATURE` | `0.2` | chat completion temperature |
| `LMLINE_FIX_TEMPERATURE` | `0.1` | sampling temperature for fix mode |
| `LMLINE_MAX_TOKENS` | `1200` | max response tokens for command modes |
| `LMLINE_EXPLAIN_MAX_TOKENS` | `1200` | max response tokens for `explain` |
| `LMLINE_CLIP_MAX_TOKENS` | `1200` | max response tokens for `clip` |
| `LMLINE_EXPLAIN_DETAIL` | `normal` | `brief`, `normal`, or `detailed` |
| `LMLINE_EXPLAIN_MAX_OUTPUT_BYTES` | `65536` | displayed explanation byte limit |
| `LMLINE_CLIP_MAX_OUTPUT_BYTES` | `65536` | displayed clip response byte limit |
| `LMLINE_MAX_CANDIDATE_BYTES` | `4096` | candidate byte limit |
| `LMLINE_ENGINE` | installed engine | engine executable |
| `LMLINE_REWRITE_BACKEND` | `engine` | rewrite provider: `engine` or `copilot` |
| `LMLINE_GENERATE_BACKEND` | `engine` | generate provider: `engine` or `copilot` |
| `LMLINE_FIX_BACKEND` | `engine` | fix provider: `engine` or `copilot` |
| `LMLINE_COPILOT_TIMEOUT` | `15000` | Copilot LSP request timeout in milliseconds |
| `LMLINE_COPILOT_RUNTIME_DIR` | `$LMLINE_CONFIG_DIR/copilot/runtime` | Copilot daemon runtime directory |
| `LMLINE_COPILOT_COMMAND` | empty | optional Language Server executable override |
| `LMLINE_PROMPT_DIR` | installed prompts | prompt override directory |
| `LMLINE_PROMPT_VERSION` | `3` | prompt/context version marker used in request keys |
| `LMLINE_RESPONSE_LOCALE` | locale-derived when locale context is enabled | response language selector |
| `LMLINE_TRACE_DIR` | empty | trace output directory |

</details>

<details>
<summary>Interactive settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_CANDIDATE_COUNT` | `3` | requested candidate count, clamped to 1..10 |
| `LMLINE_ASYNC` | `0` | background generation |
| `LMLINE_ASYNC_NOTIFY` | `0` | announce finished background generation at the next prompt |
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
| `LMLINE_NO_LOCK` | `0` | disable config-dir locking |
| `LMLINE_LOCK_TIMEOUT` | `5` | seconds to wait for the config lock |
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
| `LMLINE_TOOL_COMMAND_INFO` | `0` | enable `command_info` (opt-in: only exact `1` enables version probes) |
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
| `LMLINE_MAX_TOOL_ROUNDS` | `4` | maximum tool-use rounds |
| `LMLINE_MAX_TOOL_CALLS_PER_ROUND` | `20` | per-round tool call limit |
| `LMLINE_TOOL_RESULT_MAX_BYTES` | `8000` | tool result bytes kept per call after condensation |
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
| `LMLINE_SUGGESTED_COMMANDS_LIMIT` | `120` | suggested commands sent per request |
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
| `LMLINE_CONDENSE_LINE_BYTES` | `2000` | per-line byte cap during output condensation |
| `LMLINE_CONDENSE_RESCUE_LINES` | `20` | priority lines rescued from the omitted middle |
| `LMLINE_CONDENSE_PATTERNS_FILE` | installed defaults | priority pattern file for condensation |

</details>

<details>
<summary>Data-file settings</summary>

| Setting | Default | Meaning |
| --- | --- | --- |
| `LMLINE_SUGGESTED_COMMANDS_FILE` | user override or installed default | suggested command list |
| `LMLINE_FILE_SEARCH_EXCLUDES_FILE` | user override or installed default | `files` tool exclude list |
| `LMLINE_SHELL_SYNTAX_WORDS_FILE` | user override or installed default | words ignored by command availability validation |
| `LMLINE_COMMAND_PREFIX_WORDS_FILE` | user override or installed default | command prefixes ignored before command extraction |
| `LMLINE_SHELL_WORDS_FILE` | user override or installed default | programs that run a command string given to them |
| `LMLINE_RISK_PATTERNS_FILE` | user override or installed default | candidate risk rules |
| `LMLINE_RISK_PIPED_SHELL_LEVEL` | `high` | level for pipe-to-shell structural risk |
| `LMLINE_RISK_HISTORY_EXPANSION_LEVEL` | `high` | level for default-character interactive history references (`low`, `medium`, `high`; invalid/empty uses `high`) |
| `LMLINE_RISK_UNRESOLVED_VAR_LEVEL` | `medium` | level for unresolved variable command structural risk |
| `LMLINE_RISK_BRACE_CAPPED_LEVEL` | `medium` | level for capped brace expansion structural risk |
| `LMLINE_RISK_RECURSIVE_REMOVE_LEVEL` | `high` | level for a recursive remove in any flag order (`low`, `medium`, `high`; invalid/empty uses `high`) |
| `LMLINE_PROJECT_CONFIG` | `0` | load project-local `.lmline.bash` files |
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

Commit subjects follow the rule the check states: one plain imperative
sentence describing the change, with no internal identifier. The rule and the
check live together in `scripts/check-commit-subjects.sh`, which checks the
subjects, and `./scripts/publish-check.sh` runs the same check.

`bash scripts/privacy-scan.sh` keeps the private data of the machine that
wrote the code out of the tree: local paths and user names, private host
names, credentials, personal addresses and secret-like file names. It reads
the tree it is given, so it answers the same wherever it is run. The publish
check runs the same scan.
