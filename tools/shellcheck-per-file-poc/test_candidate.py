#!/usr/bin/env python3
"""Focused, bounded tests. Requires the pinned CLI; never runs the full manifest."""
from collections import Counter
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock

import candidate as c


class CandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shellcheck = os.environ.get("SHELLCHECK", "shellcheck")
        version = c.measure([cls.shellcheck, "--version"])
        if version["status"] != 0 or f"version: {c.PIN}\n" not in version["stdout"]:
            raise RuntimeError("tests require the pinned ShellCheck CLI (set SHELLCHECK)")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shellcheck-per-file-", dir=c.ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def file(self, name, content):
        path = self.root / name
        path.write_text(content)
        return str(path)

    def run_candidate(self, files, **kwargs):
        report = c.run(files, self.shellcheck, rcfile=c.ROOT / ".shellcheckrc", timeout=20, **kwargs)
        self.assertTrue(report["complete"], report)
        for target in report["targets"]:
            self.assertGreater(target["measurement"]["peak_rss_kib"], 0)
            self.assertGreaterEqual(target["measurement"]["elapsed_s"], 0)
        return report

    def combined(self, files, rc=True):
        command = [self.shellcheck, "-s", "bash", "--format=json"]
        if rc:
            command += ["--rcfile=" + str(c.ROOT / ".shellcheckrc")]
        result = c.measure(command + [c.canonical(p) for p in files], timeout=20)
        self.assertFalse(result["errors"], result)
        self.assertFalse(result["stderr"], result)
        self.assertIn(result["status"], (0, 1))
        return json.loads(result["stdout"])

    def assert_rows(self, actual, expected):
        # Full objects, including fix, and duplicate multiplicity, not just keys.
        def multiset(rows):
            return Counter(json.dumps(row, sort_keys=True) for row in rows)
        self.assertEqual(multiset(actual), multiset(expected))

    def test_manifest_matches_shell_harness_without_running_it(self):
        harness = (c.ROOT / "tests/test_shellcheck.sh").read_text()
        invocation = harness.split("  shellcheck -s bash \\\n", 1)[1].split("  || fail", 1)[0]
        # Evaluate only the literal argument list, not any harness functions.
        for line in invocation.splitlines():
            self.assertRegex(line, r'^  "\$repo_dir(?:/[-a-zA-Z0-9_./]+"|"/[-a-zA-Z0-9_./*]+) \\$')
        result = subprocess.run(["bash", "-c", 'repo_dir=$1; printf "%s\\0" ' + invocation,
                                 "manifest-test", str(c.ROOT)], capture_output=True, check=True)
        actual = result.stdout.decode().rstrip("\0").split("\0")
        manifest = list(map(c.canonical, c.production_manifest()))
        self.assertEqual(actual, manifest)
        self.assertEqual(len(manifest), 74)
        self.assertEqual(len(set(manifest)), 74)
        declarations = [(p, d) for p in manifest for d in c.sources(p, set(manifest))]
        self.assertEqual(len(declarations), 135)
        self.assertTrue(all(d["in_manifest"] for _, d in declarations))
        self.assertEqual(len({(p, d["resolved"]) for p, d in declarations}), 131)
        groups = [{p} | {d["resolved"] for d in c.sources(p, set(manifest))} for p in manifest]
        self.assertEqual(max(map(len, groups)), 10)

    def test_chain_relative_absolute_duplicates_and_null(self):
        a, b, d = [str(self.root / name) for name in ("a.sh", "b.sh", "c.sh")]
        relative_b = os.path.relpath(b, c.ROOT)
        self.file("a.sh", f'#!/bin/bash\n# shellcheck source={relative_b}\n. "$dynamic"\necho $a\n')
        self.file("b.sh", f'#!/bin/bash\n# shellcheck source={d}\n. "$dynamic"\necho $b\n')
        self.file("c.sh", '#!/bin/bash\necho $c\n# shellcheck source=/dev/null\n. "$dynamic"\n')
        # Context before target, mixed path spelling, repeated target occurrence.
        absolute = [d, b, a, a, "/dev/null"]
        relative = [os.path.relpath(p, c.ROOT) for p in absolute]
        baseline = self.combined(absolute)
        self.assertTrue(any(row["code"] == 2086 and row.get("fix") for row in baseline))
        for inputs in (absolute, relative):
            with self.subTest(inputs=inputs):
                report = self.run_candidate(inputs)
                self.assertEqual(report["status"], 1)
                self.assertEqual(len(report["targets"]), 5)
                self.assertEqual(report["targets"][2]["group"], [b, a])
                self.assertEqual(report["targets"][3]["group"], [b, a])
                self.assertEqual(report["targets"][1]["group"], [d, b])
                self.assertNotIn(d, report["targets"][2]["group"])
                self.assert_rows(report["target_diagnostics"], baseline)
                a_rows = [row for row in baseline if row["file"] == a]
                self.assertEqual(len(a_rows), 2 * len(report["targets"][2]["target_diagnostics"]))
                self.assertEqual(report["targets"][4]["target_diagnostics"], [])
        # /dev/null annotation must not be added as context if absent from manifest.
        report = self.run_candidate([d])
        self.assertEqual(report["targets"][0]["group"], [d])
        self.assertEqual(report["source_counts"]["outside_manifest"], 1)
        self.assertNotIn(1091, [r["code"] for r in report["target_diagnostics"]])

    def test_non_manifest_sources_are_not_followed(self):
        dependency = self.file("outside.sh", '#!/bin/bash\necho $outside\n')
        target = self.file("target.sh", f'#!/bin/bash\n# shellcheck source={dependency}\n. "$dynamic"\n')
        report = self.run_candidate([target])
        self.assertEqual(report["targets"][0]["group"], [target])
        self.assertEqual(report["source_counts"]["outside_manifest"], 1)
        self.assert_rows(report["target_diagnostics"], self.combined([target]))
        self.assertIn(1091, [row["code"] for row in report["target_diagnostics"]])

    def test_exact_rc_and_implicit_project_rc(self):
        path = self.file("rc.sh", '#!/bin/bash\nunused=one\necho $value\n')
        report = self.run_candidate([path])
        self.assertEqual({r["code"] for r in report["target_diagnostics"]}, {2086})
        without_rc = c.measure([self.shellcheck, "--norc", "-s", "bash", "--format=json", path])
        self.assertIn(2034, [r["code"] for r in json.loads(without_rc["stdout"])])
        # Existing real input: no rc override at all in the production API path.
        files = ["scripts/install-shellcheck.sh"]
        implicit = c.run(files, self.shellcheck, timeout=20)
        explicit = self.run_candidate(files)
        self.assertTrue(implicit["complete"], implicit)
        self.assert_rows(implicit["target_diagnostics"], explicit["target_diagnostics"])
        command = implicit["targets"][0]["measurement"]["command"]
        self.assertFalse(any(arg.startswith("--rcfile") for arg in command))
        self.assertNotIn("-x", command)
        self.assertNotIn("--external-sources", command)

    def test_real_source_context_subset(self):
        files = ["lmline/profiles.bash", "tests/lib.sh", "tests/test_endpoint_display.sh"]
        report = c.run(files, self.shellcheck, timeout=20)
        self.assertTrue(report["complete"], report)
        self.assert_rows(report["target_diagnostics"], self.combined(files, rc=False))
        self.assertEqual(report["target_diagnostics"], [])

    def fake(self, body):
        path = Path(self.file("fake-shellcheck", f'#!{sys.executable}\nimport sys, json, os, signal\n'
                             'if sys.argv[1:] == ["--version"]:\n'
                             ' print("version: 0.11.0"); sys.exit(0)\n' + body))
        path.chmod(0o755)
        return str(path)

    def test_all_targets_run_after_errors_and_failure_wins(self):
        log = self.root / "calls"
        fake = self.fake(f'''with open({str(log)!r}, "a") as stream: stream.write(sys.argv[-1] + "\\n")
name = os.path.basename(sys.argv[-1])
if name == "exit.sh": print("[]"); sys.exit(3)
if name == "json.sh": print("not json"); sys.exit(0)
if name == "stderr.sh": print("[]"); print("unexpected", file=sys.stderr); sys.exit(0)
if name == "signal.sh": os.kill(os.getpid(), signal.SIGTERM)
if name == "shape.sh": print('{{}}'); sys.exit(0)
if name == "mismatch.sh": print("[]"); sys.exit(1)
print("[]")
''')
        names = ["exit.sh", "json.sh", "stderr.sh", "signal.sh", "shape.sh", "mismatch.sh", "ok.sh", "ok.sh"]
        files = [self.file(name, "#!/bin/bash\n") for name in names]
        report = c.run(files, fake)
        self.assertEqual(report["status"], 2)
        self.assertFalse(report["complete"])
        self.assertEqual(log.read_text().splitlines(), files)
        self.assertEqual([t["status"] for t in report["targets"]], [2] * 6 + [0, 0])
        self.assertEqual(report["targets"][3]["measurement"]["status"], -15)

    def test_context_rows_do_not_set_target_status_and_rows_are_lossless(self):
        dependency = self.file("dependency.sh", "#!/bin/bash\n")
        target = self.file("target.sh", f"#!/bin/bash\n# shellcheck source={dependency}\n. ignored\n")
        row = dict(file=dependency, line=2, column=1, endLine=2, endColumn=5,
                   level="warning", code=2086, message="quote", fix={"replacements": []},
                   extra={"preserve": True})
        fake = self.fake(f"print(json.dumps([{row!r}, {row!r}]))\nsys.exit(1)\n")
        report = c.run([target, dependency, dependency], fake)
        self.assertTrue(report["complete"], report)
        self.assertEqual([t["status"] for t in report["targets"]], [0, 1, 1])
        self.assertEqual(report["status"], 1)
        self.assertEqual(report["target_diagnostics"], [row] * 4)
        self.assertEqual(report["targets"][0]["group_diagnostics"], [row] * 2)

    def test_caps_timeout_missing_tool_and_bad_version_fail_closed(self):
        files = [self.file("a.sh", "#!/bin/bash\n"), self.file("b.sh", "#!/bin/bash\n")]
        for body, kwargs in [('print("x" * 4096)\n', {"cap": 1024}),
                             ('import time; time.sleep(5)\n', {"timeout": 0.15})]:
            fake = self.fake(body)
            report = c.run(files, fake, **kwargs)
            self.assertEqual(report["status"], 2)
            self.assertEqual(len(report["targets"]), 2)
            self.assertTrue(all(t["errors"] for t in report["targets"]))
            self.assertTrue(all(len(t["measurement"]["stdout"]) <= kwargs.get("cap", c.OUTPUT_CAP)
                                for t in report["targets"]))
        report = c.run(files, str(self.root / "missing"))
        self.assertEqual(report["status"], 2)
        self.assertEqual(len(report["targets"]), 2)
        fake = self.fake('print("[]")\n')
        Path(fake).write_text(Path(fake).read_text().replace("0.11.0", "0.10.0"))
        report = c.run(files, fake)
        self.assertEqual(report["status"], 2)
        self.assertTrue(report["errors"])

    def test_rss_is_per_child_not_parent_cumulative_max(self):
        large = c.measure([sys.executable, "-c", 'data = bytearray(64 * 1024 * 1024)'])
        small = c.measure([sys.executable, "-c", 'pass'])
        self.assertEqual(large["status"], 0)
        self.assertEqual(small["status"], 0)
        self.assertGreater(large["peak_rss_kib"], small["peak_rss_kib"] + 32 * 1024)

    def read_records(self, output):
        text = output.read_text()
        self.assertTrue(text.endswith("\n"))
        return [json.loads(line) for line in text.splitlines()]

    def test_record_stream_preserves_in_memory_report(self):
        path = self.file("a.sh", "#!/bin/bash\necho $value\n")
        records = []
        report = c.run([path, path], self.shellcheck, rcfile=c.ROOT / ".shellcheckrc",
                       timeout=20, record=records.append)
        self.assertEqual([r["type"] for r in records],
                         ["header", "version", "target_start", "target", "target_start", "target", "summary"])
        # Reconstruct every existing report field, including diagnostic multiplicity.
        rebuilt = {k: v for r in (records[0], records[1], records[-1])
                   for k, v in r.items() if k != "type"}
        rebuilt["targets"] = [{k: v for k, v in r.items() if k != "type"}
                              for r in records if r["type"] == "target"]
        rebuilt["target_diagnostics"] = [d for t in rebuilt["targets"]
                                         for d in t["target_diagnostics"]]
        self.assertEqual(rebuilt, report)
        self.assertEqual(report["status"], 1)
        self.assertTrue(report["complete"])

    def test_cli_report_and_report_write_failure(self):
        log = self.root / "calls"
        fake = self.fake(f'with open({str(log)!r}, "a") as stream: stream.write("target\\n")\n'
                         'print("[]")\n')
        path = self.file("a.sh", "#!/bin/bash\n")
        output = self.root / "evidence.jsonl"
        command = [sys.executable, str(Path(c.__file__)), "--shellcheck", fake,
                   "--report", str(output), path]
        result = subprocess.run(command, cwd=self.root, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")  # No progress unless explicitly requested.
        self.assertEqual(result.stderr, b"")
        records = self.read_records(output)
        self.assertEqual([r["type"] for r in records], ["header", "version", "target_start", "target", "summary"])
        self.assertEqual(records[0]["manifest"], [path])
        self.assertEqual(records[-1]["status"], 0)
        self.assertTrue(records[-1]["complete"])
        self.assertEqual(records[-1]["source_counts"]["declarations"], 0)
        self.assertEqual(records[3]["measurement"]["stdout"], "[]\n")
        for destination in (output, self.root / "missing" / "evidence.jsonl"):
            with self.subTest(destination=destination):
                # No version probe or target may start if exclusive open fails.
                with mock.patch.object(sys, "argv", ["candidate", "--report", str(destination), path]), \
                        mock.patch.object(c, "measure") as measure, redirect_stderr(io.StringIO()) as err:
                    self.assertEqual(c.main(), 2)
                measure.assert_not_called()
                self.assertIn("evidence report failure", err.getvalue())
        self.assertEqual(log.read_text(), "target\n")
        self.assertEqual(self.read_records(output), records)

    def test_cli_flushes_before_children_and_survives_later_failure_or_cancellation(self):
        first = self.file("first.sh", "#!/bin/bash\n")
        later = self.file("later.sh", "#!/bin/bash\n")
        row = dict(file=first, line=1, column=1, endLine=1, endColumn=2,
                   level="warning", code=2086, message="quote café", fix={"replacements": []})
        for cancel in (False, True):
            with self.subTest(cancel=cancel):
                output = self.root / ("cancel.jsonl" if cancel else "failure.jsonl")
                # Each child independently reads the file, before parent close or
                # final serialization. No polling, sleeps, or buffering assumptions.
                fake = self.fake(f'''from pathlib import Path
records = [json.loads(line) for line in Path({str(output)!r}).read_text().splitlines()]
assert records[-1]["type"] == "target_start"
records = [r for r in records if r["type"] != "target_start"]
assert records[0]["type"] == "header"
assert records[1]["type"] == "version"
if sys.argv[-1] == {later!r}:
 assert [r["type"] for r in records] == ["header", "version", "target"]
 assert records[2]["group_diagnostics"] == {([row] * 2)!r}
 assert json.loads(records[2]["measurement"]["stdout"]) == {([row] * 2)!r}
 if {cancel!r}:
  os.kill(os.getppid(), signal.SIGTERM); sys.exit(0)
 print("not JSON"); sys.exit(0)
print(json.dumps({([row] * 2)!r})); sys.exit(1)
''')
                # Version child checks that even the header was flushed before
                # the first process starts, not merely before the first target.
                script = Path(fake).read_text().replace(
                    ' print("version: 0.11.0"); sys.exit(0)',
                    f' from pathlib import Path\n'
                    f' records = [json.loads(line) for line in Path({str(output)!r}).read_text().splitlines()]\n'
                    ' assert [r["type"] for r in records] == ["header"]\n'
                    ' print("version: 0.11.0"); sys.exit(0)')
                Path(fake).write_text(script)
                result = subprocess.run([sys.executable, str(Path(c.__file__)), "--shellcheck", fake,
                                         "--report", str(output), first, later, first],
                                        capture_output=True, timeout=10)
                records = [r for r in self.read_records(output) if r["type"] != "target_start"]
                self.assertEqual(records[2]["target_diagnostics"], [row] * 2)
                self.assertEqual(records[2]["status"], 1)
                if cancel:
                    self.assertEqual(result.returncode, -signal.SIGTERM, result.stderr)
                    self.assertEqual([r["type"] for r in records], ["header", "version", "target"])
                else:
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual([r["type"] for r in records],
                                     ["header", "version", "target", "target", "target", "summary"])
                    self.assertEqual([r["status"] for r in records[2:-1]], [1, 2, 1])
                    self.assertEqual(records[-1]["status"], 2)
                    self.assertFalse(records[-1]["complete"])

    def test_report_flush_failure_stops_without_success_summary(self):
        class FailingStream(io.StringIO):
            def flush(self):
                if len(self.getvalue().splitlines()) == 3:
                    raise OSError("simulated report flush failure")

            def close(self):
                pass  # Keep the captured evidence available for assertions.

        stream = FailingStream()
        original_open = Path.open

        def open_report(path, *args, **kwargs):
            if path == Path("unused.jsonl"):
                self.assertEqual(args, ("x",))
                return stream
            return original_open(path, *args, **kwargs)

        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake('print("[]")\n')
        with mock.patch.object(sys, "argv", ["candidate", "--shellcheck", fake,
                                           "--report", "unused.jsonl", path, path]), \
                mock.patch.object(Path, "open", open_report), \
                mock.patch.object(c, "measure", wraps=c.measure) as measure, \
                redirect_stderr(io.StringIO()) as err:
            self.assertEqual(c.main(), 2)
        self.assertEqual(measure.call_count, 1)  # Start flush failed: no target may launch.
        self.assertIn("evidence report failure", err.getvalue())
        self.assertEqual([json.loads(line)["type"] for line in stream.getvalue().splitlines()],
                         ["header", "version", "target_start"])


class ProgressTests(unittest.TestCase):
    # Fake CLI coverage is independent of pinned-CLI availability. Fixtures live
    # inside ROOT so progress must use real repo-relative paths, not ../ aliases.
    file = CandidateTests.file
    fake = CandidateTests.fake
    read_records = CandidateTests.read_records

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="progress-fixture-", dir=c.ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def command(self, output, fake, files, progress=True):
        return [sys.executable, str(Path(c.__file__)), "--shellcheck", fake,
                "--report", str(output)] + (["--progress"] if progress else []) + files

    def assert_safe(self, text):
        self.assertNotIn("DISTINCTIVE_RAW_DIAGNOSTIC", text)
        self.assertNotIn(str(c.ROOT), text)
        self.assertNotIn(str(self.root), text)
        for line in text.splitlines(keepends=True):
            self.assertTrue(line.endswith("\n"))
            self.assertLessEqual(len(line.encode("ascii")), c.PROGRESS_BYTES)
            row = json.loads(line)
            self.assertFalse({"command", "arguments", "stdout", "stderr", "message",
                              "measurement", "errors", "manifest", "cwd"} & row.keys())

    def workflow_script(self, step):
        # Exercise the actual workflow shell/gate without a YAML dependency.
        workflow = (c.ROOT / ".github/workflows/shellcheck-per-file-diagnostic.yml").read_text()
        block = workflow.split("      - name: " + step + "\n", 1)[1]
        return textwrap.dedent(block.split("        run: |\n", 1)[1].split("      - name:", 1)[0])

    def measurement(self, fake, files):
        evidence = self.root / "shellcheck-per-file-diagnostic"
        evidence.mkdir(exist_ok=True)
        # Only substitute the small fixture manifest entry point and fake CLI;
        # keep the workflow's pipeline, redirections and status handling intact.
        entry = (f"import sys; sys.path.insert(0, {str(Path(c.__file__).parent)!r}); "
                 "from candidate import main; "
                 "print('DISTINCTIVE_RAW_DIAGNOSTIC /private/path --argument', file=sys.stderr); "
                 f"sys.exit(main({files!r}))")
        script = self.workflow_script("Measure the full manifest once").replace(
            "python3 tools/shellcheck-per-file-poc/run_manifest.py",
            shlex.join([sys.executable, "-c", entry]))
        cli = self.root / "shellcheck"
        cli.write_bytes(Path(fake).read_bytes())
        cli.chmod(0o755)
        live = self.root / "live.log"
        with live.open("w") as stream:
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                    env=dict(os.environ, RUNNER_TEMP=str(self.root),
                                             SC_BIN_DIR=str(self.root)),
                                    stdout=stream, stderr=subprocess.PIPE, text=True, timeout=10)
        self.assertEqual(result.stderr, "")
        self.assert_safe(live.read_text())
        return result.returncode, evidence, live.read_text()

    def summarize(self, output, files, status, outcome):
        evidence = self.root / "shellcheck-per-file-diagnostic"
        evidence.mkdir(exist_ok=True)
        (evidence / "manifest.jsonl").write_bytes(output.read_bytes())
        (evidence / "exit-status.txt").write_text(str(status) + "\n")
        script = self.workflow_script("Summarize without raw transcript")
        gate = script.split("python3 - <<'PY'\n", 1)[1].rsplit("PY\n", 1)[0]
        # Match the fixture manifest so rejection cannot be a manifest mismatch.
        setup = (f"import sys; sys.path.insert(0, {str(Path(c.__file__).parent)!r}); "
                 f"import candidate; candidate.production_manifest = lambda: {files!r}\n")
        result = subprocess.run([sys.executable, "-c", setup + gate], capture_output=True,
                                text=True, timeout=5,
                                env=dict(os.environ, RUNNER_TEMP=str(self.root),
                                         MEASUREMENT_OUTCOME=outcome,
                                         GITHUB_STEP_SUMMARY=str(self.root / "step-summary.md")))
        self.assertEqual(result.stdout + result.stderr, "")
        return result.returncode, (evidence / "summary.md").read_text()

    def test_workflow_pipeline_streams_only_progress_and_retains_full_evidence(self):
        first = self.file("first.sh", "#!/bin/bash\n")
        later = self.file("later.sh", "#!/bin/bash\n")
        marker = "DISTINCTIVE_RAW_DIAGNOSTIC " + str(self.root) + " --raw-argument"
        row = dict(file=first, line=1, column=1, endLine=1, endColumn=2,
                   level="warning", code=2086, message=marker, fix={"replacements": []})
        for status in (0, 1, 2):
            with self.subTest(status=status):
                fake = self.fake(f'''from pathlib import Path
import time
if sys.argv[-1] == {later!r}:
 # Both destinations must be live before this CLI invocation can finish.
 deadline = time.monotonic() + 3
 while True:
  try:
   logs = [Path({str(self.root)!r}) / name for name in
           ("live.log", "shellcheck-per-file-diagnostic/measurement.log")]
   if all(any(json.loads(line).get("type") == "target_start" and json.loads(line).get("index") == 1
              for line in p.read_text().splitlines()) for p in logs):
    break
  except (OSError, ValueError):
   pass
  assert time.monotonic() < deadline, "progress was not live"
  time.sleep(0.01)
 if {status} == 2:
  print({marker!r}); print({marker!r}, file=sys.stderr); sys.exit(3)
 print("[]"); sys.exit(0)
print(json.dumps({[row] if status else []!r})); sys.exit({int(bool(status))})
''')
                code, evidence, live = self.measurement(fake, [first, later])
                self.assertEqual(code, status)
                self.assertEqual((evidence / "exit-status.txt").read_text(), f"{status}\n")
                self.assertEqual(live, (evidence / "measurement.log").read_text())
                records = self.read_records(evidence / "manifest.jsonl")
                self.assertEqual(live, "".join(c.progress_record(record) for record in records))
                records = [r for r in records if r["type"] != "target_start"]
                self.assertEqual(records[2]["measurement"]["command"][-1], first)
                if status:
                    self.assertEqual(records[2]["group_diagnostics"], [row])
                    self.assertEqual(records[2]["target_diagnostics"], [row])
                    self.assertIn(marker, records[2]["measurement"]["stdout"])
                if status == 2:
                    self.assertEqual(records[3]["measurement"]["stderr"], marker + "\n")
                    self.assertEqual(records[3]["measurement"]["stdout"], marker + "\n")
                summary_code, summary = self.summarize(evidence / "manifest.jsonl", [first, later],
                                                     status, "success" if status == 0 else "failure")
                self.assertEqual(summary_code, int(status == 2))
                self.assertIn("Incomplete:" if status == 2 else "Complete measurement:", summary)
                (evidence / "manifest.jsonl").unlink()

    def test_workflow_tee_failure_is_fatal_and_silent(self):
        path = self.file("clean.sh", "#!/bin/bash\n")
        fake = self.fake('print("[]")\n')
        evidence = self.root / "shellcheck-per-file-diagnostic"
        evidence.mkdir()
        (evidence / "measurement.log").mkdir()  # tee cannot write a directory.
        code, evidence, live = self.measurement(fake, [path])
        self.assertEqual(code, 2)
        self.assertEqual((evidence / "exit-status.txt").read_text(), "0\n")
        records = self.read_records(evidence / "manifest.jsonl")
        self.assertTrue(records[-1]["complete"])
        self.assertEqual(live, "".join(c.progress_record(record) for record in records))
        code, summary = self.summarize(evidence / "manifest.jsonl", [path], 0, "failure")
        self.assertEqual(code, 1)
        self.assertIn("Incomplete:", summary)

    def test_cli_progress_is_sanitized_lossless_evidence_and_opt_in(self):
        dependency = self.file("dependency.sh", "#!/bin/bash\n")
        first = self.file("first.sh", f"#!/bin/bash\n# shellcheck source={dependency}\n")
        later = self.file("later.sh", "#!/bin/bash\n")
        marker = "DISTINCTIVE_RAW_DIAGNOSTIC " + str(self.root) + " --raw-argument"
        row = dict(file=dependency, line=1, column=1, endLine=1, endColumn=2,
                   level="warning", code=2086, message=marker, fix={"replacements": []})
        for bad in (False, True):
            for progress in (False, True):
                with self.subTest(bad=bad, progress=progress):
                    output = self.root / f"evidence-{bad}-{progress}.jsonl"
                    fake = self.fake(f'''if sys.argv[-1] == {later!r}:
 if {bad!r}:
  print({marker!r}); print({marker!r}, file=sys.stderr); sys.exit(3)
 print("[]"); sys.exit(0)
print(json.dumps({([row] * 2)!r})); sys.exit(1)
''')
                    script = Path(fake).read_text().replace(
                        ' print("version: 0.11.0"); sys.exit(0)',
                        f' print("version: 0.11.0"); print({marker!r}); sys.exit(0)')
                    Path(fake).write_text(script)
                    result = subprocess.run(self.command(output, fake, [first, dependency, later], progress),
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 2 if bad else 1, result.stderr)
                    self.assertEqual(result.stderr, "")
                    all_records = self.read_records(output)
                    records = [r for r in all_records if r["type"] != "target_start"]
                    self.assertIn(marker, records[1]["version"]["stdout"])
                    self.assertEqual(records[2]["group_diagnostics"], [row] * 2)
                    self.assertEqual(records[2]["target_diagnostics"], [])
                    self.assertEqual(records[3]["target_diagnostics"], [row] * 2)
                    self.assertIn(marker, records[2]["measurement"]["stdout"])
                    self.assertEqual(records[-1]["status"], result.returncode)
                    if bad:
                        self.assertEqual(records[4]["measurement"]["stderr"], marker + "\n")
                        self.assertEqual(records[4]["measurement"]["stdout"], marker + "\n")
                    if not progress:
                        self.assertEqual(result.stdout, "")
                        continue
                    self.assert_safe(result.stdout)
                    rows = [json.loads(line) for line in result.stdout.splitlines()]
                    self.assertEqual(rows, [json.loads(c.progress_record(record)) for record in all_records])
                    self.assertEqual(rows[0], dict(type="header", schema=1, target_count=3))
                    self.assertEqual(rows[1], dict(type="version", schema=1, pinned_version=c.PIN, status=0))
                    targets = [r for r in rows if r["type"] == "target"]
                    self.assertEqual([r["index"] for r in targets], [0, 1, 2])
                    self.assertEqual([r["status"] for r in targets], [0, 1, 2 if bad else 0])
                    self.assertEqual([r["target_diagnostic_count"] for r in targets], [0, 2, 0])
                    for projected, full in zip(targets, records[2:-1]):
                        self.assertEqual(projected["target"], Path(full["target"]).relative_to(c.ROOT).as_posix())
                        for key in ("elapsed_s", "peak_rss_kib"):
                            self.assertEqual(projected[key], full["measurement"][key])
                            self.assertGreater(projected[key], 0)
                        self.assertEqual(projected["tool_status"], full["measurement"]["status"])

    def test_clean_cli_with_and_without_progress(self):
        fake = self.fake('print("[]")\n')
        path = self.file("clean.sh", "#!/bin/bash\n")
        for progress in (False, True):
            output = self.root / f"clean-{progress}.jsonl"
            result = subprocess.run(self.command(output, fake, [path], progress),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            if progress:
                self.assert_safe(result.stdout)
                self.assertEqual(json.loads(result.stdout.splitlines()[-1])["status"], 0)
            else:
                self.assertEqual(result.stdout, "")
            self.assertTrue(self.read_records(output)[-1]["complete"])

    def test_progress_is_flushed_before_later_shutdown(self):
        first = self.file("first.sh", "#!/bin/bash\n")
        later = self.file("later.sh", "#!/bin/bash\n")
        output = self.root / "evidence.jsonl"
        progress = self.root / "progress.jsonl"
        fake = self.fake(f'''from pathlib import Path
records = [json.loads(line) for line in Path({str(progress)!r}).read_text().splitlines()]
assert records[-1]["type"] == "target_start"
records = [r for r in records if r["type"] != "target_start"]
assert [r["type"] for r in records[:2]] == ["header", "version"]
if sys.argv[-1] == {later!r}:
 assert [r["type"] for r in records] == ["header", "version", "target"]
 assert records[2]["index"] == 0 and records[2]["status"] == 0
 os.kill(os.getppid(), signal.SIGTERM)
print("[]")
''')
        with progress.open("w") as stream:
            result = subprocess.run(self.command(output, fake, [first, later]),
                                    stdout=stream, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(result.returncode, -signal.SIGTERM, result.stderr)
        self.assert_safe(progress.read_text())
        self.assertEqual([r["type"] for r in self.read_records(progress)], ["header", "version", "target_start", "target", "target_start"])
        self.assertEqual([r["type"] for r in self.read_records(output)], ["header", "version", "target_start", "target", "target_start"])
        # Even a stale successful exit-status/outcome cannot turn a flushed
        # prefix into a complete measurement or lint pass.
        for status, outcome in ((128 + signal.SIGTERM, "failure"), (0, "success")):
            code, summary = self.summarize(output, [first, later], status, outcome)
            self.assertEqual(code, 1)
            self.assertIn("Incomplete:", summary)
            self.assertIn("never a lint pass", summary)
            self.assertNotIn("Complete measurement:", summary)

    def test_unrepresentable_target_and_log_failure_fail_safely(self):
        class FailingStream(io.StringIO):
            def flush(self):
                raise OSError("DISTINCTIVE_RAW_DIAGNOSTIC /absolute/path --argument")

        fake = self.fake('print("[]")\n')
        loop = self.root / "loop.sh"
        loop.symlink_to(loop.name)
        for name in ("/dev/null", self.file("control\x1b.sh", "#!/bin/bash\n"), str(loop)):
            with self.subTest(name=name):
                output = self.root / (Path(name).name + ".jsonl")
                result = subprocess.run(self.command(output, fake, [name]),
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assert_safe(result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stderr), dict(type="failure", schema=1, status=2))
                # Full target evidence was flushed first, without a false summary.
                self.assertEqual([r["type"] for r in self.read_records(output)], ["header", "version", "target"])
        target = dict(type="target", index=0, target=str(c.ROOT / ("x" * c.PROGRESS_BYTES)),
                      measurement=None, status=2, target_diagnostics=[], errors=["raw"])
        with self.assertRaises((OSError, ValueError)):
            c.progress_record(target)
        output = self.root / "sink-failure.jsonl"
        with mock.patch.object(sys, "argv", self.command(output, fake, ["install.sh"])[1:]), \
                mock.patch.object(c, "measure") as measure, \
                redirect_stdout(FailingStream()), redirect_stderr(io.StringIO()) as err:
            self.assertEqual(c.main(), 2)
        measure.assert_not_called()
        self.assert_safe(err.getvalue())
        self.assertEqual(json.loads(err.getvalue()), dict(type="failure", schema=1, status=2))
        self.assertEqual([r["type"] for r in self.read_records(output)], ["header"])


class FakeResource:
    """No filesystem/cgroup operations; only real, tiny test child processes."""
    def __init__(self, rows=None, setup_error=False, placement_error=False, cleanup_error=False, final_row=None):
        self.rows = rows or [dict.fromkeys(c.COUNTERS, 0)]
        self.final_row = final_row
        self.finishing = False
        self.setup_error = setup_error
        self.placement_error = placement_error
        self.cleanup_error = cleanup_error
        self.path = Path("/fake-only/child")
        self.calls = []
        self.reads = 0

    def setup(self):
        self.calls.append("setup")
        if self.setup_error:
            raise OSError("fake setup failure")

    def place(self):
        if self.placement_error:
            raise OSError("fake placement failure")

    def sample(self):
        self.calls.append("sample")
        row = self.final_row if self.finishing and self.final_row is not None else self.rows[min(self.reads, len(self.rows) - 1)]
        self.reads += 1
        if isinstance(row, Exception):
            raise row
        return row

    def kill(self):
        self.calls.append("kill-all")

    def cleanup(self, final_sample):
        self.calls.append("cleanup")
        self.kill()
        if self.cleanup_error:
            raise OSError("fake unknown quiescence")
        self.finishing = True
        final_sample()
        return dict(quiescent=True, removed=True)


class ResourceTests(unittest.TestCase):
    setUp = ProgressTests.setUp
    file = CandidateTests.file
    fake = CandidateTests.fake
    summarize = ProgressTests.summarize
    workflow_script = ProgressTests.workflow_script
    config = dict(parent="/fake-only", memory_bytes=1000, cpu_usec=2000, cpu_quota_usec=50000, cpu_period_usec=100000)

    def measured(self, resource, body="print('[]')", **kwargs):
        with mock.patch.object(c, "CgroupGuard", return_value=resource):
            return c.measure([sys.executable, "-c", body], guard=self.config, timeout=2, **kwargs)

    def test_guard_is_explicit_off_by_default_and_partial_options_never_launch(self):
        with mock.patch.object(c, "CgroupGuard") as factory:
            result = c.measure([sys.executable, "-c", "pass"])
        self.assertEqual(result["status"], 0)
        self.assertNotIn("guard", result)
        factory.assert_not_called()
        for options in (["--cgroup-parent", "/fake-only"], ["--memory-bytes", "1"],
                        ["--cgroup-parent", "/fake-only", "--memory-bytes", "1", "--cpu-usec", "1",
                         "--cpu-quota-usec", "1", "--cpu-period-usec", "0"],
                        ["--cgroup-parent", "/fake-only", "--memory-bytes", "1", "--cpu-usec", "1",
                         "--cpu-quota-usec", str(2**64), "--cpu-period-usec", "1"],
                        ["--cgroup-parent", "/fake-only", "--memory-bytes", "1", "--cpu-usec", "1"]):
            with self.subTest(options=options), mock.patch.object(sys, "argv", ["candidate", "--report", "unused", *options, "install.sh"]), mock.patch.object(c, "measure") as measure, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    c.main()
                self.assertEqual(error.exception.code, 2)
                measure.assert_not_called()

    def test_setup_and_preexec_placement_failures_never_exec_or_fallback(self):
        marker = self.root / "executed"
        for kwargs in (dict(setup_error=True), dict(placement_error=True)):
            resource = FakeResource(**kwargs)
            result = self.measured(resource, f"from pathlib import Path; Path({str(marker)!r}).touch()")
            self.assertIsNone(result["status"])
            self.assertTrue(result["errors"])
            self.assertFalse(marker.exists())
            self.assertIn("kill-all", resource.calls)
            self.assertIn("cleanup", resource.calls)

    def test_counters_allowlist_missing_and_invalid_values_fail_before_exec(self):
        for key in c.COUNTERS:
            for value in ("unavailable", -1, True, "raw/private/text", 2**64):
                row = dict.fromkeys(c.COUNTERS, 0)
                row[key] = value
                resource = FakeResource([row])
                result = self.measured(resource)
                self.assertIsNone(result["status"])
                self.assertTrue(result["errors"])
        resource = FakeResource([dict.fromkeys(c.COUNTERS, 0) | {"pid": 999, "stderr": "PRIVATE"}])
        seen = []
        result = self.measured(resource, observe=seen.append, index=4)
        self.assertFalse(result["errors"], result)
        self.assertTrue(seen)
        self.assertEqual(seen, result["guard"]["samples"])
        for row in seen:
            self.assertEqual(set(row), {"type", "index", "sample", *c.COUNTERS})
            self.assertLessEqual(len(c.progress_record(row).encode("ascii")), 1024)
            self.assertNotIn("PRIVATE", json.dumps(row))

    def test_memory_cpu_oom_limits_kill_and_force_incomplete_preserving_child_status(self):
        zero = dict.fromkeys(c.COUNTERS, 0)
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        for key, value in (("memory_current", 1000), ("memory_peak", 1000), ("cpu_usage_usec", 2000), ("oom", 1), ("oom_kill", 1)):
            with self.subTest(counter=key):
                # Version is healthy; the target's final scoped sample breaches
                # its budget after the original exit status has been reaped.
                resource = FakeResource(final_row=zero | {key: value})
                records = []
                with mock.patch.object(c, "CgroupGuard", side_effect=[FakeResource(), resource]):
                    report = c.run([path], fake, guard=self.config, record=records.append)
                self.assertEqual(report["status"], 2)
                self.assertFalse(report["complete"])
                measured = report["targets"][0]["measurement"]
                self.assertEqual(measured["status"], 0)
                self.assertTrue(measured["errors"])
                self.assertIn("kill-all", resource.calls)
                self.assertTrue(any(r["type"] == "resource_sample" and r[key] == value for r in records))
        # A running child is also stopped, without waiting for the wall budget.
        with mock.patch.object(c, "SAMPLE_INTERVAL", 0.01):
            resource = FakeResource([zero, zero | {"cpu_usage_usec": 2000}])
            measured = self.measured(resource, "import time; time.sleep(1)")
        self.assertEqual(measured["status"], -signal.SIGKILL)
        self.assertTrue(measured["errors"])

    def test_observer_sample_count_and_total_bytes_fail_closed(self):
        for constant, value in (("SAMPLE_COUNT", 1), ("SAMPLE_BYTES", 1)):
            with self.subTest(cap=constant), mock.patch.object(c, constant, value):
                resource = FakeResource()
                result = self.measured(resource)
                self.assertTrue(result["errors"])
                self.assertLessEqual(len(result["guard"]["samples"]), 1)
                self.assertIn("kill-all", resource.calls)
        def fail(row):
            raise OSError("fake observer/sink failure")
        for resource, observe in ((FakeResource(), fail), (FakeResource([OSError("fake observer read")]), None)):
            result = self.measured(resource, observe=observe)
            self.assertIsNone(result["status"])
            self.assertTrue(result["errors"])
            self.assertIn("kill-all", resource.calls)
        # Later progress failure still retains original status and failure
        # evidence in a usable artifact sink; never reports successful lint.
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        records = []
        resource = FakeResource()
        def sink(row):
            records.append(row)
            if row["type"] == "resource_sample" and resource.finishing:
                raise OSError("fake live sink failure")
        with mock.patch.object(c, "CgroupGuard", side_effect=[FakeResource(), resource]):
            report = c.run([path], fake, guard=self.config, record=sink)
        self.assertEqual(report["status"], 2)
        target = next(r for r in records if r["type"] == "target")
        self.assertEqual(target["measurement"]["status"], 0)
        self.assertIn("fake live sink failure", str(target["errors"]))
        self.assertFalse(records[-1]["complete"])

    def test_existing_output_wall_bounds_and_child_outcomes_with_fake_guard(self):
        for body, kwargs, error in (("print('x' * 1000)", dict(cap=32), "byte cap"),
                                    ("import time; time.sleep(1)", dict(timeout=0.04), "timeout")):
            resource = FakeResource()
            # Override the helper's default timeout without duplicate kwargs.
            with mock.patch.object(c, "CgroupGuard", return_value=resource):
                result = c.measure([sys.executable, "-c", body], guard=self.config, **kwargs)
            self.assertIn(error, str(result["errors"]))
            self.assertLessEqual(len(result["stdout"]), kwargs.get("cap", c.OUTPUT_CAP))
            self.assertIn("kill-all", resource.calls)
            self.assertEqual(result["guard"]["cleanup"], dict(quiescent=True, removed=True))
        for status in (0, 1, 7):
            result = self.measured(FakeResource(), f"import sys; sys.exit({status})")
            self.assertEqual(result["status"], status)
            self.assertFalse(result["errors"])
        result = self.measured(FakeResource(cleanup_error=True), "import sys; sys.exit(1)")
        self.assertEqual(result["status"], 1)
        self.assertEqual(result["guard"]["cleanup"], dict(quiescent=False, removed=False))
        self.assertIn("reserved", str(result["errors"]))

    def test_unknown_cleanup_stops_following_targets_and_retains_outcome(self):
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        with mock.patch.object(c, "CgroupGuard", side_effect=[FakeResource(), FakeResource(cleanup_error=True)]) as factory:
            report = c.run([path, path], fake, guard=self.config)
        self.assertEqual(factory.call_count, 2)  # Version, first target; never a replacement.
        self.assertEqual(len(report["targets"]), 1)
        self.assertEqual(report["targets"][0]["measurement"]["status"], 0)
        self.assertEqual(report["status"], 2)
        self.assertFalse(report["complete"])
        result = self.measured(FakeResource(), "import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
        self.assertEqual(result["status"], -signal.SIGTERM)

    def test_start_allowlist_bounds_and_failed_flush_prevent_target_launch(self):
        row = dict(type="target_start", index=0, target="install.sh", group_count=2,
                   command="PRIVATE", pid=42, stderr="PRIVATE")
        self.assertEqual(json.loads(c.progress_record(row)),
                         dict(type="target_start", schema=1, index=0, target="install.sh", group_count=2))
        for target in ("/private/not-repo", "../outside", "x\x1b.sh", "x" * 1024):
            with self.assertRaises((ValueError, OSError)):
                c.progress_record(row | dict(target=target))
        def fail_start(row):
            if row["type"] == "target_start":
                raise OSError("fake start flush failure")
        fake = self.fake("print('[]')\n")
        with mock.patch.object(c, "measure", wraps=c.measure) as measure:
            with self.assertRaises(c.EvidenceFailure):
                c.run(["install.sh"], fake, record=fail_start)
        self.assertEqual(measure.call_count, 1)

    def test_workflow_validates_guard_records_and_rejects_partial_or_tampered_samples(self):
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        records = []
        with mock.patch.object(c, "CgroupGuard", side_effect=lambda config: FakeResource()):
            report = c.run([path], fake, guard=self.config, record=records.append)
        self.assertEqual(report["status"], 0)
        output = self.root / "guard.jsonl"
        def check(rows, expected):
            output.write_text("".join(json.dumps(r) + "\n" for r in rows))
            code, text = self.summarize(output, [path], 0, "success")
            self.assertEqual(code, expected, text)
        check(records, 0)
        sample_index = next(i for i, r in enumerate(records) if r["type"] == "resource_sample")
        check(records[:sample_index + 1], 1)
        check([r for i, r in enumerate(records) if i != sample_index], 1)
        for change in (dict(sample=99), dict(memory_peak="raw"), dict(stderr="raw"), dict(index=8)):
            changed = list(records)
            changed[sample_index] = changed[sample_index] | change
            check(changed, 1)

    def test_cpu_quota_period_explicit_and_aggregate_separately_enforced(self):
        # Limits are passed through verbatim; no defaults are guessed.
        resource = FakeResource()
        measured = self.measured(resource)
        self.assertEqual(measured["guard"]["limits"], self.config)
        self.assertEqual(measured["guard"]["sample_interval_s"], c.SAMPLE_INTERVAL)
        self.assertIn("cpu_quota_usec", measured["guard"]["limits"])
        self.assertIn("cpu_period_usec", measured["guard"]["limits"])
        # Aggregate usage is still enforced independently of the rate quota.
        for key, value in (("memory_current", 1000), ("memory_peak", 1000),
                            ("cpu_usage_usec", 2000), ("oom", 1), ("oom_kill", 1)):
            row = dict.fromkeys(c.COUNTERS, 0) | {key: value}
            res = FakeResource([row])
            result = self.measured(res)
            self.assertIsNone(result["status"])
            self.assertTrue(result["errors"])
            self.assertIn("kill-all", res.calls)

    def test_final_limit_breach_still_removes_proven_empty_leaf(self):
        zero = dict.fromkeys(c.COUNTERS, 0)
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        for key, value in (("memory_current", 1000), ("memory_peak", 1000),
                            ("cpu_usage_usec", 2000), ("oom", 1), ("oom_kill", 1)):
            with self.subTest(counter=key):
                resource = FakeResource(final_row=zero | {key: value})
                records = []
                with mock.patch.object(c, "CgroupGuard", side_effect=[FakeResource(), resource]):
                    report = c.run([path], fake, guard=self.config, record=records.append)
                self.assertEqual(report["status"], 2)
                self.assertFalse(report["complete"])
                measured = report["targets"][0]["measurement"]
                # Original child outcome is preserved; enforcement is recorded.
                self.assertEqual(measured["status"], 0)
                self.assertTrue(measured["errors"])
                # Proven-empty leaf is still removed; only reservation blocks release.
                self.assertEqual(measured["guard"]["cleanup"], dict(quiescent=True, removed=True))
                self.assertEqual(measured["terminated_by_signal"], None)
                self.assertTrue(any(r["type"] == "resource_sample" and r[key] == value for r in records))

    def test_final_sample_count_cap_still_removes_proven_empty_leaf(self):
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        resource = FakeResource()
        measure = c.measure

        def capped_measure(command, **kwargs):
            if "--version" in command:
                return measure(command, **kwargs)
            # Only the initial sample fits. Disable periodic sampling so the
            # cap is reached at final capture, after the child exits normally.
            with mock.patch.object(c, "SAMPLE_COUNT", 1), mock.patch.object(c, "SAMPLE_INTERVAL", float("inf")):
                return measure(command, **kwargs)

        with mock.patch.object(c, "CgroupGuard", side_effect=[FakeResource(), resource]), \
                mock.patch.object(c, "measure", side_effect=capped_measure):
            report = c.run([path], fake, guard=self.config)
        self.assertEqual(report["status"], 2)
        self.assertFalse(report["complete"])
        measured = report["targets"][0]["measurement"]
        self.assertEqual(measured["status"], 0)
        self.assertIn("wrapper failure: ValueError: resource sample count cap", measured["errors"])
        self.assertEqual(len(measured["guard"]["samples"]), 1)
        self.assertEqual(measured["guard"]["cleanup"], dict(quiescent=True, removed=True))

    def test_final_sink_failure_still_removes_but_reports_incomplete(self):
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        records = []
        resource = FakeResource()
        def sink(row):
            records.append(row)
            if row["type"] == "resource_sample" and resource.finishing:
                raise OSError("fake live sink failure")
        with mock.patch.object(c, "CgroupGuard", side_effect=[FakeResource(), resource]):
            report = c.run([path], fake, guard=self.config, record=sink)
        self.assertEqual(report["status"], 2)
        self.assertFalse(report["complete"])
        measured = next(r for r in records if r["type"] == "target")["measurement"]
        self.assertEqual(measured["status"], 0)
        self.assertIn("fake live sink failure", str(measured["errors"]))
        self.assertEqual(measured["guard"]["cleanup"], dict(quiescent=True, removed=True))

    def test_termination_during_guarded_child_kill_quiescence_before_removal(self):
        # Deterministic: second sample (first polling after exec) signals self.
        resource = FakeResource()
        orig_sample = resource.sample
        calls = {"n": 0}
        def signalling_sample():
            calls["n"] += 1
            if calls["n"] == 2:
                import os as _os, signal as _sig
                _os.kill(_os.getpid(), _sig.SIGTERM)
            return orig_sample()
        resource.sample = signalling_sample
        measured = self.measured(resource, "import time; time.sleep(5)")
        self.assertEqual(measured["terminated_by_signal"], signal.SIGTERM)
        self.assertTrue(any("terminated by signal" in e for e in measured["errors"]))
        # Child was killed promptly; original kill outcome is preserved.
        self.assertEqual(measured["status"], -signal.SIGKILL)
        self.assertIn("kill-all", resource.calls)
        self.assertEqual(resource.calls.count("kill-all") >= 1, True)
        # Quiescence was proven before removal (FakeResource cleanup succeeded).
        self.assertEqual(measured["guard"]["cleanup"], dict(quiescent=True, removed=True))
        # Order: kill was attempted before cleanup finished.
        self.assertLess(resource.calls.index("kill-all"), len(resource.calls) - 1)

    def test_guard_requires_signal_handlers_and_records_signal_during_cleanup(self):
        marker = self.root / "must-not-exec"
        resource = FakeResource()
        with mock.patch.object(c.signal, "signal", side_effect=ValueError("not main thread")):
            result = self.measured(resource, f"from pathlib import Path; Path({str(marker)!r}).touch()")
        self.assertIsNone(result["status"])
        self.assertTrue(result["errors"])
        self.assertFalse(marker.exists())
        self.assertIn("cleanup", resource.calls)

        class TerminatedDuringCleanup(FakeResource):
            def cleanup(self, final_capture):
                os.kill(os.getpid(), signal.SIGTERM)
                return super().cleanup(final_capture)

        result = self.measured(TerminatedDuringCleanup())
        self.assertEqual(result["status"], 0)
        self.assertEqual(result["terminated_by_signal"], signal.SIGTERM)
        self.assertTrue(any("terminated by signal" in error for error in result["errors"]))
        self.assertEqual(result["guard"]["cleanup"], dict(quiescent=True, removed=True))

    def test_termination_stops_further_targets_after_bounded_cleanup(self):
        first = self.file("first.sh", "#!/bin/bash\n")
        later = self.file("later.sh", "#!/bin/bash\n")
        fake = self.fake("import time; time.sleep(2)\nprint('[]')\n")
        records = []
        seen = {"n": 0}
        def record(row):
            records.append(row)
            # Second polled sample of the first target signals while child active.
            if row["type"] == "resource_sample" and row["index"] == 0:
                seen["n"] += 1
                if seen["n"] == 2:
                    import os as _os, signal as _sig
                    _os.kill(_os.getpid(), _sig.SIGTERM)
        resources = [FakeResource(), FakeResource(), FakeResource()]
        with mock.patch.object(c, "CgroupGuard", side_effect=resources):
            report = c.run([first, later], fake, guard=self.config, record=record)
        self.assertEqual(len(report["targets"]), 1)
        self.assertEqual(report["status"], 2)
        self.assertFalse(report["complete"])
        measured = report["targets"][0]["measurement"]
        self.assertEqual(measured["terminated_by_signal"], signal.SIGTERM)
        self.assertEqual(measured["guard"]["cleanup"], dict(quiescent=True, removed=True))

    def test_workflow_summary_rejects_missing_starts_samples_cleanup(self):
        path = self.file("a.sh", "#!/bin/bash\n")
        fake = self.fake("print('[]')\n")
        records = []
        with mock.patch.object(c, "CgroupGuard", side_effect=lambda config: FakeResource()):
            report = c.run([path], fake, guard=self.config, record=records.append)
        self.assertEqual(report["status"], 0)
        output = self.root / "guard-strict.jsonl"
        def check(rows, expected):
            output.write_text("".join(json.dumps(r) + "\n" for r in rows))
            code, text = self.summarize(output, [path], 0, "success")
            self.assertEqual(code, expected, text)
        # Valid guarded evidence is accepted.
        check(records, 0)
        kinds = [r["type"] for r in records]
        start_idx = kinds.index("target_start")
        sample_idxs = [i for i, r in enumerate(records) if r["type"] == "resource_sample"]
        target_idx = kinds.index("target")
        # Missing start is rejected.
        check([r for i, r in enumerate(records) if i != start_idx], 1)
        # Missing any sample is rejected (proven samples must all be present).
        check([r for i, r in enumerate(records) if i not in sample_idxs], 1)
        check([r for i, r in enumerate(records) if i != sample_idxs[0]], 1)
        # Tampered cleanup (reserved) is rejected.
        tampered = [dict(r) for r in records]
        for row in tampered:
            if row["type"] == "target" and row.get("measurement", {}).get("guard") is not None:
                row["measurement"] = dict(row["measurement"])
                row["measurement"]["guard"] = dict(row["measurement"]["guard"])
                row["measurement"]["guard"]["cleanup"] = dict(quiescent=False, removed=False)
        check(tampered, 1)
        # Wrong order (target before samples) is rejected.
        reordered = [r for r in records if r["type"] != "target"] + [r for r in records if r["type"] == "target"]
        # Reordered still has same multiset but wrong event order for samples vs target.
        # Build an explicitly misordered stream: target before its samples.
        misordered = []
        for r in records:
            if r["type"] == "target":
                # Insert target before preceding samples by moving it earlier.
                misordered.insert(start_idx, r)
            else:
                misordered.append(r)
        # The above keeps order; instead craft a direct violation: swap start and target.
        swapped = list(records)
        swapped[start_idx], swapped[target_idx] = swapped[target_idx], swapped[start_idx]
        check(swapped, 1)
        # Extra unexpected sample field is rejected via strict schema.
        extra = list(records)
        extra[sample_idxs[0]] = extra[sample_idxs[0]] | dict(extra_field="raw")
        check(extra, 1)
        # Any valid sample count within bounds is accepted when events exactly
        # match the retained measurement: a slower child yields more polls.
        slow_fake = self.fake("import time; time.sleep(0.35)\nprint('[]')\n")
        slow_records = []
        with mock.patch.object(c, "CgroupGuard", side_effect=lambda config: FakeResource()):
            slow_report = c.run([path], slow_fake, guard=self.config, record=slow_records.append)
        self.assertEqual(slow_report["status"], 0)
        slow_samples = [r for r in slow_records if r["type"] == "resource_sample"]
        self.assertGreater(len(slow_samples), len(sample_idxs))
        slow_output = self.root / "guard-slow.jsonl"
        slow_output.write_text("".join(json.dumps(r) + "\n" for r in slow_records))
        code, text = self.summarize(slow_output, [path], 0, "success")
        self.assertEqual(code, 0, text)


class CgroupFilesystemTests(unittest.TestCase):
    """Exercise real guard decisions using fake kernel files, never cgroup writes."""
    def setUp(self):
        self.parent = Path("/fake-cgroups")
        self.child = self.parent / "child"
        self.fs = {
            "/proc/self/mountinfo": "1 0 0:1 / /fake-cgroups rw - cgroup2 cgroup rw\n",
            str(self.parent / "cgroup.controllers"): "cpu memory",
            str(self.parent / "cgroup.subtree_control"): "cpu memory",
        }
        for name, value in {"cgroup.procs": "", "cgroup.events": "populated 0\n", "cgroup.kill": "",
                            "memory.max": "max", "memory.current": "0", "memory.peak": "0",
                            "memory.events": "oom 0\noom_kill 0\n", "cpu.max": "max 100000",
                            "cpu.stat": "usage_usec 0\n"}.items():
            self.fs[str(self.child / name)] = value
        self.writes = []
        def read(path, *args, **kwargs):
            if str(path) not in self.fs:
                raise FileNotFoundError("fake missing file")
            return self.fs[str(path)]
        def write(path, value, *args, **kwargs):
            # Faithful fake: store the exact bytes written; never rewrite "0" into a PID.
            # The real kernel rejects "0" in a leaf cgroup.procs, so the test must
            # assert the child's own PID was written.
            self.writes.append((path.name, value))
            self.fs[str(path)] = value
        self.addCleanup(mock.patch.stopall)
        for name, value in (("read_text", read), ("write_text", write),
                            ("resolve", lambda path: path),
                            ("is_file", lambda path: str(path) in self.fs)):
            mock.patch.object(Path, name, value).start()
        self.mkdir = mock.patch.object(c.tempfile, "mkdtemp", return_value=str(self.child)).start()
        self.remove = mock.patch.object(Path, "rmdir").start()
        mock.patch.object(Path, "open", mock.mock_open()).start()
        self.guard = c.CgroupGuard(ResourceTests.config | dict(parent=str(self.parent)))

    def test_v2_controller_preflight_memory_readback_and_placement(self):
        self.guard.setup()
        self.assertIn(("memory.max", "1000"), self.writes)
        self.assertIn(("cpu.max", "50000 100000"), self.writes)
        self.guard.place()
        # The forked child must write its own PID; "0" is invalid in a leaf.
        pid = str(os.getpid())
        self.assertIn(("cgroup.procs", pid), self.writes)
        self.assertNotIn(("cgroup.procs", "0"), self.writes)
        self.assertEqual(self.fs[str(self.child / "cgroup.procs")], pid)
        self.assertEqual(self.guard.sample(), dict.fromkeys(c.COUNTERS, 0))
        del self.fs[str(self.child / "memory.peak")]
        self.assertEqual(self.guard.sample()["memory_peak"], "unavailable")
        self.fs[str(self.child / "memory.events")] = "oom 1\n"
        self.assertEqual(self.guard.sample()["oom"], 1)
        self.assertEqual(self.guard.sample()["oom_kill"], "unavailable")
        with mock.patch.object(Path, "write_text", side_effect=PermissionError("fake denial")):
            with self.assertRaises(PermissionError):
                self.guard.place()

    def test_placement_writes_own_pid_and_readback_cannot_silently_fail(self):
        self.guard.setup()
        with mock.patch.object(Path, "write_text", return_value=1):
            with self.assertRaises(ValueError):
                self.guard.place()  # No simulated membership change on this write.
        # Successful placement must write the child's own PID, never literal "0".
        self.guard.place()
        procs_writes = [v for k, v in self.writes if k == "cgroup.procs"]
        self.assertTrue(procs_writes)
        self.assertTrue(all(v != "0" for v in procs_writes))
        self.assertTrue(all(v == str(os.getpid()) for v in procs_writes))
        self.assertEqual(self.fs[str(self.child / "cgroup.procs")], str(os.getpid()))
    def test_placement_and_memory_limit_readback_cannot_silently_fail(self):
        self.guard.setup()
        self.fs[str(self.child / "memory.max")] = "max"
        with mock.patch.object(Path, "write_text", return_value=1):
            with self.assertRaises(ValueError):
                self.guard.setup()
        self.fs[str(self.child / "memory.max")] = "1000"
        self.fs[str(self.child / "cpu.max")] = "max 100000"
        with mock.patch.object(Path, "write_text", return_value=1):
            with self.assertRaises(ValueError):
                self.guard.setup()

    def test_preflight_rejects_non_v2_missing_controllers_and_required_files(self):
        for file, value in (("/proc/self/mountinfo", "1 0 0:1 / /fake-cgroups rw - tmpfs tmpfs rw\n"),
                            (str(self.parent / "cgroup.subtree_control"), "cpu"),
                            (str(self.parent / "cgroup.controllers"), "memory")):
            original = self.fs[file]
            self.fs[file] = value
            with self.assertRaises(ValueError):
                self.guard.setup()
            self.mkdir.assert_not_called()
            self.fs[file] = original
        original_mounts = self.fs["/proc/self/mountinfo"]
        self.fs["/proc/self/mountinfo"] = (original_mounts.replace("/fake-cgroups rw", "/ rw") +
                                          "2 1 0:2 / /fake-cgroups rw - tmpfs tmpfs rw\n")
        with self.assertRaises(ValueError):
            self.guard.setup()  # A nested non-cgroup mount cannot inherit v2 identity.
        self.mkdir.assert_not_called()
        self.fs["/proc/self/mountinfo"] = original_mounts
        del self.fs[str(self.child / "cgroup.kill")]
        with self.assertRaises(ValueError):
            self.guard.setup()
        self.assertNotIn(("memory.max", "1000"), self.writes)

    def test_descendants_require_authoritative_quiescence_before_release(self):
        self.guard.setup()
        for events in ("populated 1\n", "", "populated unknown\n"):
            self.fs[str(self.child / "cgroup.events")] = events
            with mock.patch.object(c, "QUIESCE_SECONDS", 0):
                with self.assertRaises(ValueError):
                    self.guard.cleanup(lambda: None)
            self.remove.assert_not_called()
            self.assertIn(("cgroup.kill", "1"), self.writes)
        self.fs[str(self.child / "cgroup.events")] = "populated 0\n"
        observed = []
        cleanup = self.guard.cleanup(lambda: observed.append("final scoped counters"))
        self.assertEqual(cleanup, dict(quiescent=True, removed=True))
        self.assertEqual(observed, ["final scoped counters"])
        self.remove.assert_called_once()
        self.remove.reset_mock()
        with mock.patch.object(Path, "read_text", side_effect=OSError("fake observer loss")):
            with self.assertRaises(OSError):
                self.guard.cleanup(lambda: None)
        self.remove.assert_not_called()
        with mock.patch.object(Path, "write_text", side_effect=OSError("fake kill failure")):
            with self.assertRaises(OSError):
                self.guard.cleanup(lambda: None)
        self.remove.assert_not_called()

    def test_quiescence_transition_final_observation_and_removal_failure(self):
        self.guard.setup()
        reads = iter(("populated 1\n", "populated 0\n"))
        original = Path.read_text
        def events(path, *args, **kwargs):
            if path.name == "cgroup.events":
                return next(reads)
            return original(path, *args, **kwargs)
        final = mock.Mock()
        with mock.patch.object(Path, "read_text", events), mock.patch.object(c.time, "sleep"):
            self.assertEqual(self.guard.cleanup(final), dict(quiescent=True, removed=True))
        final.assert_called_once()
        self.remove.reset_mock()
        with mock.patch.object(Path, "rmdir", side_effect=OSError("fake busy")):
            with self.assertRaises(OSError):
                self.guard.cleanup(lambda: None)
        def failed_final():
            raise OSError("fake final observer failure")
        with self.assertRaises(OSError):
            self.guard.cleanup(failed_final)
        self.remove.assert_not_called()

    def test_cpu_quota_period_required_applied_and_read_back(self):
        # Explicit finite quota and period are required; no defaults exist.
        for bad in (dict(cpu_quota_usec=0, cpu_period_usec=100000),
                    dict(cpu_quota_usec=50000, cpu_period_usec=0),
                    dict(cpu_quota_usec=2**63, cpu_period_usec=100000),
                    dict(cpu_quota_usec=50000, cpu_period_usec=2**63),
                    dict(cpu_quota_usec=True, cpu_period_usec=100000)):
            bad_config = dict(self.guard.config) | bad
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    c.CgroupGuard(bad_config).setup()
                self.mkdir.assert_not_called()
        for missing in ("cpu_quota_usec", "cpu_period_usec", "cpu_usec", "memory_bytes"):
            bad_config = dict(self.guard.config)
            del bad_config[missing]
            with self.subTest(missing=missing):
                with self.assertRaises((ValueError, KeyError)):
                    c.CgroupGuard(bad_config).setup()
        # Applied and read back verbatim.
        self.guard.setup()
        self.assertIn(("cpu.max", "50000 100000"), self.writes)
        self.assertEqual(self.fs[str(self.child / "cpu.max")], "50000 100000")
        # Readback mismatch is a failure, never silent use of a wrong quota.
        self.fs[str(self.child / "cpu.max")] = "1 100000"
        with mock.patch.object(Path, "write_text", return_value=1):
            with self.assertRaises(ValueError):
                self.guard.setup()

    def test_missing_cpu_max_file_fails_preflight(self):
        del self.fs[str(self.child / "cpu.max")]
        with self.assertRaises(ValueError):
            self.guard.setup()
        self.assertNotIn(("memory.max", "1000"), self.writes)
        self.assertNotIn(("cpu.max", "50000 100000"), self.writes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
