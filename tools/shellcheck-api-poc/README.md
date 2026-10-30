# ShellCheck library/API diagnostic (GPL-3.0-or-later)

This isolated experiment is **not a full ShellCheck pass, a replacement for
`tests/test_shellcheck.sh`, or a coverage workaround**. It changes no runtime,
lint configuration, default CI, source manifest, or baseline warning policy.
Do not use a successful three-file result to close full-lint acceptance.

The ordinary reviewed workflow is `.github/workflows/shellcheck-api-diagnostic.yml`.
It runs **only on manual `workflow_dispatch`**, with read-only repository access,
one `ubuntu-24.04` job, and a 40-minute job deadline. Review before manually
running it; no dispatch is part of preparing this change. Checkout does not
persist its read-only token. There is no publishing, cache restore, matrix, or
automatic trigger. Build and measurement are separate
steps in the same job; measurement reuses the compiled executable.

## Identities and lock

- GHC **9.6.6**, cabal-install **3.10.3.0**, modular solver, one build worker.
  These are separate pins, not an assumption that their versions match.
  The official [setup v2 documentation](https://github.com/haskell-actions/setup/tree/v2.8.0)
  lists both as supported exact versions. Cabal 3.10.3.0's
  [package bounds](https://hackage.haskell.org/package/cabal-install-3.10.3.0)
  allow `base >=4.10 && <4.20`, including GHC 9.6's base 4.18.
  The setup action is pinned to v2.8.0 commit
  `96f3dafd067155f32643c2a0757ab71d2910e2c2`, with `cabal-update: false`;
  the explicit bounded `cabal update` in the resolve step owns the index.
- ShellCheck v0.11.0 source commit
  `aac0823e6b58f8a499e856e93738082691cbf212`, fetched by tag `v0.11.0` and verified against that commit.
  The baseline uses the **unchanged** `scripts/install-shellcheck.sh` and
  `pinned-downloads.txt`: the official CLI archive digest and version are checked.
- Hackage index-state **2026-01-01T00:00:00Z**, fixed in `cabal.project`.
  Resolution uses the pinned cabal-install solver, then `cabal freeze` and an
  offline dry-run elaborate the actual plan **before compilation**. The build
  can download the locked package sources; it consumes the same freeze and
  fixed index-state, with `--jobs=1`. Tests/benchmarks are not built.

There is **no checked-in dependency freeze and no claim of an already pinned
plan**. The workflow generates a **per-run resolved lock artifact**. It archives
`cabal.project.freeze`, `plan.before-build.json`, their SHA-256 digests, the
post-build plan, project/driver/helper inputs, source/config digests, tool
versions, and executable digests. The freeze must remain byte-identical before
and after build and before measurement. A failed resolution/build supplies
incomplete evidence, not a fallback to a floating or different plan.

## Measurement semantics and bounds

From the repository root, the CLI command is exactly:

```sh
shellcheck -s bash --rcfile=.shellcheckrc --format=json \
  lmline/policy.bash lmline/config.bash lmline/validation-boundary.bash
```

The API executable calls `ShellCheck.Checker.checkScript` once per path, in that
order, using `emptyCheckSpec` defaults with only filename, script, and the Bash
shell override set. The system interface supplies the checked-in `.shellcheckrc`
to the analyzer unchanged. There is **no `-x`**, sourced-diagnostic flag,
extended-analysis change, optional-check change, or extra analyzer input.
The source allowlist is exactly the same three command-line inputs plus
ShellCheck's `/dev/null` special case. The existing `source=lmline/...`
annotations resolve from the repository root, so the interface's source resolver
returns that name unchanged. This is intentionally only a reproducer adapter,
not a general replacement for the CLI's search-path machinery: it fails if the
rc gains settings beyond its current `disable=` lines. If source-path/external
source annotations change, review the adapter before reusing the experiment.

The CLI and API run sequentially (no concurrent scans). The API uses
`+RTS -N1 -M3G -RTS`. Both commands have a **180-second** GNU `timeout` plus a
5-second kill grace. A separate systemd service per command enforces a **4 GiB
cgroup charged-memory limit**, **zero swap**, a 190-second service deadline,
and whole-control-group cleanup. This is not an RSS or address-space limit;
API `-M3G` bounds GHC heap, not total RSS. No `ulimit -v` is used. Lack of these
hosted-runner controls fails closed. The command-output capture is capped at
64 MiB/file and retained artifacts at 8 MiB/file. Service `LimitFSIZE` is 1 GiB
for Hackage index update (the package index is larger than the artifact cap),
256 MiB for compile/freeze/plan, and 8 MiB for analyzer runs. Compilation has
its own 900-second timeout, 4 GiB cgroup cap, and one worker; dependency
update/freeze/plan commands also have separate short bounds. Workflow step/job
deadlines are additional guards.

`commands.txt` records shell-quoted commands (repository paths replaced with
`<repo>`). For each bounded command, `.status` records the launcher result and
GNU time records elapsed seconds, peak RSS in KiB, and command exit status.
An early cgroup kill may leave the time record incomplete; that is not parity.
Command stdout/stderr capture is capped at 64 MiB/file by the launcher; after
successful collection, retained artifacts are capped at 8 MiB/file. Service
`LimitFSIZE` bounds process-created files by phase as described above; compile
products stay in the workspace and are not uploaded. The always-run artifact
step retains only the fixed results directory for seven days. No binaries,
dependency cache, or source checkout are uploaded. Summaries contain fixed
messages, not absolute runner paths (raw build logs/plans can contain runner
paths).

`compare.py` requires complete JSON and normal exit codes (0 or 1), validates
that status agrees with diagnostic presence, and compares multisets of **every
diagnostic** including duplicate multiplicity, filename, start/end positions,
severity, code, and exact message. Ordering/JSON formatting alone are ignored.
CLI suggested-edit `fix` metadata stays in the raw artifact but is not compared:
this tool tests analyzer diagnostics, not automatic edits. JSON changes only
serialization, not analysis options. Raw `cli.json`/`api.json` (or stderr) over
8 MiB is **incomplete, never parity**. A timeout, memory limit, malformed/missing
output, unexpected stderr, command error, or mismatch is **incomplete/non-parity
evidence**.

## Local review and licensing

Only bounded static checks are appropriate before dispatch: workflow trigger,
permissions/action pins/paths, Bash syntax and helper-only lint, Python syntax,
and synthetic comparator cases. GHC/Cabal are unavailable in the preparation
sandbox; **compilation and actual parity are not locally verified**. Do not run
the full 74-file lint to validate this diagnostic change.

This directory's experimental code is **GPL-3.0-or-later**, with the GPL v3 text
in `LICENSE`; it links against GPL-3.0-or-later ShellCheck. It is not installed by
lmline or imported by the product. The root lmline MIT `LICENSE` is unchanged.
If distributing a built tool, comply with GPL corresponding-source obligations;
this workflow distributes diagnostic evidence only, not executables.
