# Per-file ShellCheck candidate (test-only)

This isolated candidate is **not an adopted replacement** for
`tests/test_shellcheck.sh`. It changes no production lint; the separate manual
diagnostic route below is opt-in only.
Python 3.9+ on Linux is required (the measurement code also normalizes Darwin's
RSS units). The CLI must be the project pin, ShellCheck 0.11.0; its version is
checked, and the existing installer verifies the pinned download's digest.

## Focused checks

From the repository root:

```bash
bin=$(sh scripts/install-shellcheck.sh) || exit
SHELLCHECK="$bin/shellcheck" python3 tools/shellcheck-per-file-poc/test_candidate.py
status=$?
rm -rf "$bin"
exit "$status"
```

The tests do **not** run the full 74-input lint. They compare complete JSON
objects as multisets (including `fix` and duplicate occurrences), using the exact
project `.shellcheckrc` via `--rcfile` only for temporary fixtures outside the
repository. They also check implicit production rc behavior, non-manifest source
exclusion, `/dev/null`, relative/absolute input spelling, source chains,
continuation after errors, output caps, timeouts, report-write failure, and
per-child rather than cumulative RSS. JSONL tests check lossless reconstruction
of the in-memory report, header/target visibility from running child processes,
retention after later tool failure or cancellation, and fail-closed flush errors. The real three-file endpoint subset is a
bounded regression test. A drift test checks the production argument list/order
without invoking ShellCheck on that list: currently 74 unique inputs, 135 source
declarations, 131 unique direct edges, maximum context group size 10.

## Candidate entry points

Resolve/provision the CLI with the existing installer as above. Explicit inputs:

```bash
python3 tools/shellcheck-per-file-poc/candidate.py \
  --shellcheck "$bin/shellcheck" --report /tmp/per-file-subset.jsonl \
  lmline/profiles.bash tests/lib.sh tests/test_endpoint_display.sh
```

The wrapper below mirrors the **exact path list/order and glob expansion** in
`tests/test_shellcheck.sh`. It is available for a separately reviewed measurement;
implementing it is not evidence that a full-manifest measurement has passed:

```bash
python3 tools/shellcheck-per-file-poc/run_manifest.py \
  --shellcheck "$bin/shellcheck" --report /tmp/per-file-manifest.jsonl
```

Use a new output filename for every invocation. Output paths are caller-relative;
input paths and annotated sources are repository-root-relative. All child
processes use repository-root cwd and absolute canonical input paths, even when
the runner is invoked elsewhere. No production entry point supplies `--rcfile`,
`--norc`, `-x`, or `--external-sources`: ShellCheck discovers the current project rc
normally, just as in the full harness. The Python module's `rcfile` argument is a
fixture-only hook, not a command-line option. There is no network/provisioning
inside the candidate itself.

## Manual GitHub Actions measurement

After normal review, dispatch **CI** with mode
`shellcheck-per-file-diagnostic` on the exact reviewed revision. The reusable
`.github/workflows/shellcheck-per-file-diagnostic.yml` is `workflow_call` only;
pushes, pull requests, and the default `full` mode do not select it. This route
provisions the exact pinned CLI, runs the focused selftests, then invokes the
full-manifest wrapper **once**, sequentially, on Ubuntu 24.04. It does not run the
combined production lint or the API probe.

The job is bounded to 40 minutes (30 minutes for the measurement). JSONL and
selftest/measurement logs live under `$RUNNER_TEMP` and are uploaded without
truncation, including on failure/incomplete runs, with 7-day retention. The step
summary contains only scope, completeness, and counts, not raw transcripts.
Missing/partial final summaries, missing target occurrences, and unsuccessful
report/process completion are reported as **incomplete**, never a lint pass.
The temporary pinned binary directory is removed after artifact upload. A hard
runner loss can still prevent always-run summary/upload/cleanup steps.

This is a resource measurement route, **not evidence of full parity or adoption**.
Even a complete clean measurement does not authorize replacing the current
production harness; equivalence review remains separate. Review artifact content
under `PUBLISHING.md` before sharing it.

## Grouping and status

For **each input occurrence**, in manifest order, the runner scans that file's
literal `# shellcheck source=...` annotations. A group consists of that target
and only its direct annotated dependencies that are also manifest members,
in original manifest order, with canonical context paths deduplicated. It runs
one sequential `shellcheck -s bash --format=json` process per target occurrence
(plus one version probe). It does not compute a transitive closure, follow
non-manifest sources, or drop duplicate target occurrences. `/dev/null` is not
added unless it is an explicit manifest member.

Group output is filtered by **exact absolute target path**, without transforming
or deduplicating any diagnostic object. Context-only rows do not determine that
target's lint status. Final exit statuses:

- **0:** complete, no collected target diagnostics;
- **1:** complete, at least one collected target diagnostic;
- **2:** incomplete/tool/wrapper/evidence failure, even if later targets pass.

Child status other than 0/1 (including signals), malformed JSON/diagnostic
shape or paths, status/JSON disagreement, unexpected stderr, wrong version,
source-resolution errors, timeout, and output overflow are recorded as errors.
Every remaining target is still attempted after tool/target errors. The final
summary's `complete` must be true before interpreting 0/1 as a lint result.
Failure to open, write, flush, or close the report returns 2 and prints an error;
evidence failures stop the run, and an existing output file is never overwritten.
The output is opened exclusively **before any ShellCheck child starts**.

## Evidence and bounds

`--report` writes schema 1 **JSON Lines** (one JSON object per newline), not
one final JSON document. Records have a `type` and occur in this order:

1. **`header`**, flushed before the version probe or any target child: `schema`,
   repo `cwd`, original `arguments`, canonical occurrence `manifest`, and `limits`.
2. **`version`**, after the probe: full `version` measurement and setup `errors`.
3. **`target`**, flushed after each input occurrence, in order: `index`, `target`,
   source declarations/resolution/membership, deduplicated `group`, full raw
   `group_diagnostics`, selected `target_diagnostics`, `errors`, computed lint
   `status`, and `measurement`. Each measurement contains the exact command, raw
   bounded stdout/stderr, **child** exit status, elapsed seconds, and peak RSS in
   KiB. Failed targets and duplicate occurrences each retain their own record.
4. **`summary`**, only after all targets: `status`, `complete`, `source_counts`,
   setup `errors`, and `total_elapsed_s`. Per-target errors stay in target records.

Every record is flushed immediately. If the job is cancelled or killed, completed
lines remain readable; the interrupted record may be absent or partial. **Missing
or partial final summary means incomplete, never success**, even if every visible
target has status 0. Accept a lint result only with a complete newline-terminated
summary, `complete: true`, status 0/1, all manifest occurrences recorded in order,
and successful report writing/process completion. A summary with status 2 is
also incomplete even though the runner reached the end. Flushing makes evidence
available to other processes; this is not an `fsync`/power-loss guarantee.

Parse each line separately with `json.loads`, dispatching on `type`; do not call
`json.load` on the whole file. Concatenating the target records' `target_diagnostics`
reconstructs the aggregate with multiplicity. The Python `run()` API still returns
the original full in-memory report (including its aggregate `target_diagnostics`);
its optional `record` callback is the CLI's incremental evidence sink. Sink errors
propagate rather than becoming tool errors or a successful final summary.
`total_elapsed_s` includes resolution, version checking, process overhead, and any
incremental record writing, but not final summary serialization.

`os.wait4` reaps each exact child PID and returns that child's resource usage;
it does not subtract or reuse the parent's cumulative `RUSAGE_CHILDREN` maximum.
Default bounds are **8 MiB per stdout/stderr stream per child** and **300 seconds
per child**, configurable with `--output-cap` and `--timeout`. Pipe buffers are
bounded in memory; overflow retains an explicitly marked prefix and kills the
child process group, forcing status 2. Invalid UTF-8 adds lossless hex evidence
and also fails. No partial/overflow output is silently accepted. The report size
scales with manifest occurrences and these per-child bounds; it deliberately
retains both raw output and parsed diagnostic objects for review.

Reports contain absolute local paths and source diagnostics. Keep them outside
the repository; review/redact before sharing under `PUBLISHING.md`.

## Review constraints

The source scanner is intentionally scoped to the current manifest's literal
annotations. It is not a shell parser or a general implementation of ShellCheck
source search: runtime `source` expressions, heredoc/comment context, recursive
resolution, `source-path` policies, and future rc/source semantics need independent
review if introduced. Malformed parsed annotations fail rather than claiming
coverage. The current rc does not enable external sources; changing that policy
would require revisiting these tests before adoption. Canonicalizing symlinked
inputs could also affect future rc discovery (the current manifest has none).

Synthetic chain and real subset parity do not establish full-manifest parity or
CI resource fitness. Those measurements/reviews remain a later step; leave the
current full-lint harness unchanged until the equivalence gaps are addressed.
