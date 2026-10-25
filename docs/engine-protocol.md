# lmline Engine Protocol

This document is the contract between the lmline frontends (Bash Readline,
zsh ZLE, and the `lmline` CLI) and the engine executable. The bundled engine
implements it; a replacement engine set via `LMLINE_ENGINE` must implement the
same interface.

## Invocation

```text
engine --mode MODE --shell SHELL --cwd DIR --point N \
       --line-file FILE --context-file FILE --n COUNT \
       [--format annotated|plain] [--dry-run-payload]
```

| Argument | Meaning |
| --- | --- |
| `--mode` | `generate`, `rewrite`, `fix`, `explain`, or `clip` |
| `--shell` | frontend shell name (`bash` or `zsh`); selects target-shell syntax validation and zsh command checks |
| `--cwd` | caller working directory; included in the prompt only when `LMLINE_INCLUDE_CWD_CONTEXT` is enabled, and always included in the response-cache identity |
| `--point` | cursor position in the line; informational, included only when `LMLINE_INCLUDE_EDITOR_CONTEXT` is enabled |
| `--line-file` | file containing the user line (for `fix`: line plus captured execution report; for `clip`: question plus redacted clipboard text) |
| `--context-file` | file containing the shell context collected by `lmline context`; sections depend on `LMLINE_INCLUDE_*` and `LMLINE_TOOL_*` settings |
| `--n` | requested candidate count (the engine clamps to 1..10) |
| `--format` | `annotated` (default) or `plain` (bare candidate lines, no risk annotations) |
| `--dry-run-payload` | print the provider request JSON to stdout and exit 0 without contacting the provider |

Settings start from the process environment. The engine then loads persistent
settings, Git-root project config, and `$PWD` project config in that order.
Later files override earlier values. Built-in defaults are applied after config
loading for unset values.

The user line is always part of the request. Environment context is controlled
by `LMLINE_INCLUDE_*` settings. Tool availability is controlled by
`LMLINE_TOOL_MODE` and per-tool `LMLINE_TOOL_*` settings. Replacement engines
must treat the context file and tool outputs as untrusted data.

## Output: command modes (`generate`, `rewrite`, `fix`)

stdout carries one protocol line per accepted candidate:

```text
lmline-candidate: <risk>\t<reason>\t<flags>\t<candidate>
```

- `risk`: `high`, `medium`, or `low`, classified by the engine using
  `risk_patterns.tsv` and structural fallbacks. The bundled engine treats
  potentially active default-character interactive history references as
  structural risk (`LMLINE_RISK_HISTORY_EXPANSION_LEVEL`, default `high`);
  replacement engines should preserve that policy. Frontends render `high`
  candidates as `# REVIEW REQUIRED:` comments and must not re-classify.
- `reason`: human-readable rule reason; tabs are replaced by spaces; `-` when
  not applicable.
- `flags`: comma-separated markers, `-` when empty. Defined flags:
  - `truncated` — the candidate was cut to `LMLINE_MAX_CANDIDATE_BYTES`
  - `original` — the user's original line appended as a cycling target
    (emitted by frontends/bridges, not the engine)
  - `copilot:<token>` — the candidate came from the Copilot route; the
    token names the edit the Language Server holds, and a frontend that
    inserts the candidate tells the server the edit was accepted
    (emitted by the bundled engine on the Copilot route)
- `candidate`: the full command text (may itself contain tabs; it is always
  the fourth and final field).

Candidates are validated and deduplicated by the engine before emission.
Validation rejects multiline text, control characters, syntax invalid for the
target shell (checked with `bash -n` or `zsh -f -n`),
environment-assignment-only command segments, selected direct directory file
operands, and command words unavailable in the target shell. The frontend for
the target shell additionally passes its own shell-function names (names only,
never bodies) in `LMLINE_SHELL_FUNCTIONS` only on the engine command for its
own shell; the engine captures that transport into a non-exported internal
variable at startup before any subprocess and unsets the transport, and the
zsh bridge child does the same at its own start before sourcing context. The
Bash fix path keeps names function-local and passes them only on its engine
command. Context and Copilot subprocesses never inherit the list. The
newline-delimited names use the validator's bounded literal command alphabet
and are matched as exact lines; a slash-containing word skips executable-path
lookup only when its exact name is present. Those names are accepted only in
the target shell's command context. Literal nested `bash -c`/`zsh -f -c` scripts
are checked in a fresh shell and never inherit the list. If the zsh syntax
validator is unavailable, zsh candidates are rejected rather than checked with
a different shell. Frontends only parse, display, and
insert.

## Output: `explain` / `clip`

stdout carries the response text with blank lines removed. No candidate
protocol lines are used.

When streaming is active (`LMLINE_STREAM=1`), text is written incrementally,
line by line, and the tool loop keeps working: streamed `tool_calls` deltas
and text-protocol `TOOL` lines are collected mid-stream, executed locally,
and the next round streams again. Token usage is taken from the provider's
`stream_options.include_usage` final chunk when available (the engine retries
once without `stream_options` for providers that reject it). The display byte
limits (`LMLINE_EXPLAIN_MAX_OUTPUT_BYTES` / `LMLINE_CLIP_MAX_OUTPUT_BYTES`)
apply to streamed output; when exceeded, emission stops and the last stdout
line is a marker:

```text
explanation-truncated original_bytes=<N> max_bytes=<M>   # explain
clip-output-truncated original_bytes=<N> max_bytes=<M>   # clip
```

A streamed round that ends without usable output and without a recognized tool call
follows the buffered request path, preserving any successfully completed tool rounds.
In particular, when an interrupted stream has emitted zero user-visible bytes, the
engine returns to buffered fallback before parsing tool-call deltas; calls from that
stream are not dispatched, even if they look valid. If an interrupted final-answer
round has emitted user-visible text and has no recognized tool call, the engine keeps
the text, appends `stream-interrupted emitted_bytes=<N>`, and does not send a buffered
retry. If an interrupted round has emitted user-visible text and contains a recognized
tool call, the engine handles it as a tool round; while the round budget permits, it
executes the calls and continues streaming without adding the marker for that round.
A local tool-round execution failure is fatal and does not trigger a buffered request,
which could repeat side effects.

## Output: stderr side channel

```text
lmline-progress: <label>      # live progress (tool calls, retries)
lmline-meta: model=... tokens=... prompt=... completion=... tools=... time=...
lmline-status: m=<model>; tok=<in>/<out>/<total>[; tools=...][; t=<N>s]
lmline-search: <query>         # a web search the provider ran (native search)
lmline-citation: <url>\t<title>  # a URL the answer cites (native search)
```

- `lmline-meta:` is machine-readable usage metadata.
- `lmline-status:` is the single preformatted status line frontends display
  verbatim (formatting lives in the engine; frontends never rebuild it).
  Cache hits emit `lmline-status: m=<model>; cached`.
- `lmline-search:` names a web search the provider ran for the answer, and
  `lmline-citation:` names a cited URL as a tab-separated URL and title. Both
  lines appear only when native web search is enabled. The provider controls
  their text, so the engine removes control characters from the query, the
  URL, and the title before printing them, and the frontends strip the lines
  like the other informational lines.
- Anything else on stderr is error text; on a non-zero exit the frontends map
  it to a short hint via `__lmline_engine_error_message`.

## Exit status

- `0` — at least one candidate or response text was produced; empty `rewrite`
  input is also a successful no-op
- `1` — provider/validation failure; stderr explains why
- `2` — usage or configuration error

## Behavior expectations

- Empty `rewrite` input exits 0 with no output.
- The engine retries transient provider failures (HTTP 429/502/503/504 and
  curl errors) `LMLINE_HTTP_RETRIES` times. On a `chat`/`responses`-format HTTP 400 naming
  `max_tokens`, `max_completion_tokens`, `max_output_tokens`, or `temperature`, it retries once without
  `temperature` (and with `max_completion_tokens` in place of `max_tokens` on `chat`).
- Provider-side request storage is explicit: the engine sends `store: false` on `chat` and `responses` payloads by default (`LMLINE_STORE=0`, fail-closed) and `store: true` when `LMLINE_STORE=1`. `messages` has no `store` field. If a provider rejects the `store` field with HTTP 400, the request fails by default; `LMLINE_STORE_FALLBACK=1` opts into one retry without the field. That fallback is limited to errors indicating the `store` field itself was rejected; a broad mention of `store` is not enough, and the retry emits an `lmline-progress:` line.
- In buffered command modes (`generate`, `rewrite`, and `fix`), an explicitly
  reported incomplete first-choice terminal status rejects the response before
  tool calls are parsed or dispatched, and before candidates are emitted or
  cached. The bundled engine recognizes only exact case-insensitive status
  values `length`, `max_tokens`, and `incomplete` (normalized from Chat
  `finish_reason`, Messages `stop_reason`, and Responses `status`), plus the
  Messages stop reason `model_context_window_exceeded`. Missing or null statuses
  and unfamiliar values remain accepted for provider compatibility; this is not
  a success-status allowlist. The bounded error recommends increasing
  `LMLINE_MAX_TOKENS` or shortening the request for token-limit statuses, and
  shortening the prompt/context for context-window exhaustion.
  `explain`/`clip` buffered behavior and streaming behavior are unchanged.
- With `LMLINE_CACHE_TTL` > 0, generate/rewrite/explain responses are
  cached under `~/.config/lmline/cache/` (mode 0700) and replayed for
  identical requests in the same declared working directory (`--cwd`). Cache
  keys include the mode, line, declared directory, model, prompt version, and
  the effective request payload (resolved prompts and sampling/output
  settings). Generate/rewrite keys also include a fixed terminal-status
  policy revision, so command entries written before incomplete-response
  validation are missed; prose entries are not invalidated. `fix` is not
  cache-eligible.
- Native local tools (`LMLINE_TOOL_MODE=openai`/`auto`) work on `chat` and `responses` (buffered tool loop); streaming (`LMLINE_STREAM`) is `chat`-only. Some reasoning models (GPT-5.4 and later) reject native tools on `chat` with HTTP 400; the engine hint then suggests `LMLINE_API_FORMAT=responses` or `LMLINE_TOOL_MODE=text`. Newer models (GPT-6 Astra/Sol) require `responses` for tool calling. The `messages` format runs buffered requests without native tool calls (`text` tool requests still apply); the engine emits an `lmline-progress:` warning when native tools or streaming are requested but disabled by the format.
- API keys are passed to curl through `-H @file` header files, never on the
  curl command line.
