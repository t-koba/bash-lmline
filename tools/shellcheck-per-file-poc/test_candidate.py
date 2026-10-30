#!/usr/bin/env python3
"""Focused, bounded tests. Requires the pinned CLI; never runs the full manifest."""
from collections import Counter
from contextlib import redirect_stderr
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
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
        self.temp = tempfile.TemporaryDirectory(prefix="shellcheck-per-file-")
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
                         ["header", "version", "target", "target", "summary"])
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
        records = self.read_records(output)
        self.assertEqual([r["type"] for r in records], ["header", "version", "target", "summary"])
        self.assertEqual(records[0]["manifest"], [path])
        self.assertEqual(records[-1]["status"], 0)
        self.assertTrue(records[-1]["complete"])
        self.assertEqual(records[-1]["source_counts"]["declarations"], 0)
        self.assertEqual(records[2]["measurement"]["stdout"], "[]\n")
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
                records = self.read_records(output)
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
        self.assertEqual(measure.call_count, 2)  # Version and first target only.
        self.assertIn("evidence report failure", err.getvalue())
        self.assertEqual([json.loads(line)["type"] for line in stream.getvalue().splitlines()],
                         ["header", "version", "target"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
