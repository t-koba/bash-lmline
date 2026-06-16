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
| `--shell` | frontend shell name (`bash` or `zsh`); informational |
| `--cwd` | caller working directory; informational, included only when `LMLINE_INCLUDE_CWD_CONTEXT` is enabled |
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

- `risk`: `high`, `medium`, or `low`, classified by the engine against
  `risk_patterns.tsv`. Frontends render `high` candidates as
  `# REVIEW REQUIRED:` comments and must not re-classify.
- `reason`: human-readable rule reason; tabs are replaced by spaces; `-` when
  not applicable.
- `flags`: comma-separated markers, `-` when empty. Defined flags:
  - `truncated` — the candidate was cut to `LMLINE_MAX_CANDIDATE_BYTES`
  - `original` — the user's original line appended as a cycling target
    (emitted by frontends/bridges, not the engine)
- `candidate`: the full command text (may itself contain tabs; it is always
  the fourth and final field).

Candidates are validated and deduplicated by the engine before emission.
Validation rejects multiline text, control characters, invalid `bash -n`,
environment-assignment-only command segments, selected direct directory file
operands, and unavailable command words. Frontends only parse, display, and
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

If streaming yields nothing usable, the engine falls back to the buffered
request path, preserving any tool rounds already performed.

## Output: stderr side channel

```text
lmline-progress: <label>      # live progress (tool calls, retries)
lmline-meta: model=... tokens=... prompt=... completion=... tools=... time=...
lmline-status: m=<model>; tok=<in>/<out>/<total>[; tools=...][; t=<N>s]
```

- `lmline-meta:` is machine-readable usage metadata.
- `lmline-status:` is the single preformatted status line frontends display
  verbatim (formatting lives in the engine; frontends never rebuild it).
  Cache hits emit `lmline-status: m=<model>; cached`.
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
  curl errors) `LMLINE_HTTP_RETRIES` times.
- With `LMLINE_CACHE_TTL` > 0, generate/rewrite/explain responses are
  cached under `~/.config/lmline/cache/` (mode 0700) and replayed for
  identical requests.
- API keys are passed to curl through `-H @file` header files, never on the
  curl command line.
