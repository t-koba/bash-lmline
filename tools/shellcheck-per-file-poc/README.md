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
project `.shellcheckrc` via `--rcfile` only for temporary fixtures in the
repository (so emitted targets are repository-relative). They also check implicit production rc behavior, non-manifest source
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

This documents the available mechanism, **not authorization to run it**. A new
measurement, including a first-group/cgroup trial, still needs separate operator
review as described below. For a separately authorized run, the route is **CI**
mode `shellcheck-per-file-diagnostic` on the exact reviewed revision. The reusable
`.github/workflows/shellcheck-per-file-diagnostic.yml` is `workflow_call` only;
pushes, pull requests, and the default `full` mode do not select it. This route
provisions the exact pinned CLI, runs the focused selftests, then invokes the
full-manifest wrapper **once**, sequentially, on Ubuntu 24.04. It does not run the
combined production lint or the API probe.

The job is bounded to 40 minutes (30 minutes for the measurement). The
`measurement.log` contains only bounded, allowlisted progress records; it does
not mirror Python stderr or ShellCheck output. Full measurements and diagnostics
remain in `manifest.jsonl`. JSONL and selftest/measurement logs live under
`$RUNNER_TEMP` and are uploaded without truncation, including on
failure/incomplete runs, with 7-day retention. The step summary contains only
scope, completeness, and counts, not raw transcripts.
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
Every remaining target is still attempted after ordinary tool/target errors.
With the optional guard, unknown cleanup stops further targets rather than
launching work beside a reserved, possibly populated cgroup. The final
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
3. **`target_start`**, before spawning each target child: only `index`,
   repository-relative `target`, and `group_count` (plus event `type`). It is
   validated to fit 1 KiB, written and flushed to retained JSONL, then projected
   and flushed through the existing `--progress | tee` live `measurement.log`
   route before exec. Invalid/unrepresentable progress paths prevent that exec.
   With the guard, bounded **`resource_sample`** events follow the start and
   precede the completed target; their only fields are `type`, `index`, `sample`,
   and the five numeric-or-`"unavailable"` counters described below.
4. **`target`**, flushed after each input occurrence, in order: `index`, `target`,
   source declarations/resolution/membership, deduplicated `group`, full raw
   `group_diagnostics`, selected `target_diagnostics`, `errors`, computed lint
   `status`, and `measurement`. Each measurement contains the exact command, raw
   bounded stdout/stderr, **child** exit status, elapsed seconds, and peak RSS in
   KiB. Failed targets and duplicate occurrences each retain their own record.
5. **`summary`**, only after all targets: `status`, `complete`, `source_counts`,
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
its optional `record` callback is the CLI's incremental evidence sink. Start/
completion sink errors propagate and stop the run. Resource-observer/sink failures
kill scoped work and retain the child outcome in the target record when the
artifact sink remains usable; neither kind can produce a successful lint result.
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


## Optional cgroup-v2 diagnostic guard (OFF by default)

This is **diagnostic-only**, not production lint or adoption. The workflow does
not enable the guard or supply trial values. An actual first-group trial remains
**unauthorized** until separate operator review of the concrete entrypoint,
source revision, pin and rc, isolation/preflight, exact finite limits, disposable
resources, and an independent cleanup procedure. No trial cap values are guessed
here. Fake-resource tests are not evidence of real isolation or parity. In
particular, OOM counters from a future scoped run cannot explain the earlier
hosted shutdown.

The candidate accepts the following **only as a complete explicit set**:
`--cgroup-parent`, `--memory-bytes`, `--cpu-usec`, `--cpu-quota-usec`, and
`--cpu-period-usec`. Budgets must be finite positive integers below 2^63; there
is no parent autodetection, fallback, or implicit cap. The canonical absolute
parent must already be on a cgroup-v2 mount with memory and CPU controllers
available and enabled for children. The runner never activates controllers or
changes parent limits. It creates a dedicated child cgroup per invocation,
including the pinned version probe, checks required controller files, sets and
reads back `memory.max` and `cpu.max` (`quota period`), and checks kill-file
access. A single-threaded pre-exec placement writes the forked child's own PID
into the leaf `cgroup.procs` and reads it back **before ShellCheck exec**;
writing literal `"0"` is invalid in a leaf and is never used. Setup/placement
failure prevents exec; it never launches an unguarded replacement.

`memory.max` is the hard kernel resident/accounted-memory ceiling (not a claim
about total memory plus swap). `cpu.max` (`quota period`) is an explicit finite
kernel CPU rate quota, applied and read back per leaf; the separate `cpu.stat`
aggregate `usage_usec` budget covers all processes in this child cgroup, not just
leader CPU or parent RSS, and is still enforced independently. Polling kills the
entire cgroup on reaching either supplied budget, an OOM event, missing counters,
or observer failure. Aggregate CPU enforcement is sampled, so breach detection
can lag one interval. Since a polling interval can straddle a quota-period
boundary, a conservative bound on additional CPU after a breach before the next
0.1-second poll is `(ceil(0.1 seconds / period) + 1) * quota`; choose the
aggregate `cpu-usec` budget with that finite overshoot in mind. The quota bounds
overshoot but never substitutes for the aggregate usage budget.

Samples use fixed bounds: 0.1-second scheduled polling (plus preflight and final
quiescent samples), at most 4096 samples and 1 MiB of serialized sample data per
invocation. Each event/projection fits 1 KiB; the byte allowance conservatively
accounts for the JSONL event, nested measurement copy and live projection when
streaming. A cap is a failure, never silent downsampling. The five fields are:
`memory_current` (`memory.current`), `memory_peak` (`memory.peak`), `oom` and
`oom_kill` (`memory.events`), and `cpu_usage_usec` (`cpu.stat usage_usec`). Missing
or unreadable counters are explicitly `"unavailable"` and fail closed. The version
probe retains its samples inside its full measurement; target samples are also
streamed as JSONL events. Full measurements retain guard limits, the child-cgroup
path for independent cleanup, samples, cleanup outcome, errors, and the original
child exit/signal status. No command, PID, raw stderr, diagnostics, absolute path,
or non-allowlisted nested data is added to live progress.

Existing wall/output bounds still apply. Any limit, timeout, output cap,
observer/logging failure, catchable termination, or uncertain cleanup means
**incomplete/status 2**, regardless of child status 0/1, while the original child
exit/signal status, metrics, and error evidence are preserved when the report sink
is usable. Even normal leader exit triggers `cgroup.kill`: descendants must not
survive it. Cleanup requires authoritative child-scoped `cgroup.events populated=0`,
within a one-second quiescence wait, followed by a non-enforcing final capture and
successful directory removal. Enforcement (aggregate/memory/OOM/counter/observer/cap
checks during polling and preflight) is separated from final capture so a detected
limit still reports status 2 but a proven-empty leaf is still removed; only unknown
quiescence, readback/shape failure, failed kill, or removal failure leaves the cgroup
**reserved**, records failure, and stops subsequent targets. There is no recursive
filesystem deletion or inference of quiescence from leader exit or RSS. Catchable
`SIGTERM`/`SIGINT` while a guarded child is active triggers bounded synchronous
kill/reap/quiescence and stops further targets after the current target record;
`SIGKILL` cannot be handled in-process and may leave a reserved leaf for the
independently reviewed supervisor/cleanup procedure, as can any runner loss. The
guard's real kernel behavior has not been exercised by these deterministic tests.
