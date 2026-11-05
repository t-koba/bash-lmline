#!/usr/bin/env python3
"""Bounded fake-CLI checks; no installed ShellCheck required."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import candidate as c
import full_batch_experiment as b


class FullBatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=c.ROOT, prefix="batch-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cli = self.root / "cli"
        self.calls = self.root / "calls"
        self.script('print("[]")')
        self.manifest = []
        for name, content in (("a", "# shellcheck source={b}\n"), ("b", "# b\n"),
                              ("c", "# c\n"), ("d", "# d\n")):
            p = self.root / name
            p.write_text(content.format(b=self.root / "b"))
            self.manifest.append(str(p))
        bounds = mock.patch.dict(os.environ, {c.TIMEOUT_ENV: str(c.TIMEOUT),
                                              c.OUTPUT_CAP_ENV: str(c.OUTPUT_CAP),
                                              b.REPORT_CAP_ENV: str(b.REPORT_CAP)})
        bounds.start()
        self.addCleanup(bounds.stop)
        self.records = []
        report = c.run(self.manifest, str(self.cli), record=self.records.append)
        self.assertTrue(report["complete"])
        self.path = self.root / "baseline.jsonl"
        self.save()
        self.calls.write_text("")

    def script(self, body):
        self.cli.write_text(f'#!{sys.executable}\nimport json, sys, time\n'
                            f'with open({str(self.calls)!r}, "a") as f: f.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                            'if sys.argv[1:] == ["--version"]:\n'
                            ' print("version: 0.11.0"); sys.exit(0)\n' + body + '\n')
        self.cli.chmod(0o755)

    def save(self):
        self.path.write_text("".join(json.dumps(r) + "\n" for r in self.records))

    def run_experiment(self):
        return b.experiment(self.path, str(self.cli), self.manifest)

    def test_packing_reuses_baseline_and_exact_commands(self):
        result = self.run_experiment()
        self.assertEqual(result["parity"], "parity")
        self.assertEqual((result["target_count"], result["batch_count"], result["batch_calls"]), (4, 2, 2))
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls, [["--version"], ["-s", "bash", "--format=json"] + self.manifest[:2],
                                ["-s", "bash", "--format=json"] + self.manifest[2:]])
        targets = [r for r in self.records if r["type"] == "target"]
        self.assertEqual(result["baseline_elapsed_s"], sum(t["measurement"]["elapsed_s"] for t in targets))
        self.assertEqual(result["baseline_peak_rss_kib"], max(t["measurement"]["peak_rss_kib"] for t in targets))
        self.assertGreater(result["batch_peak_rss_kib"], 0)
        # Byte bound, independently of file count, must also cause a split.
        Path(self.manifest[2]).write_text("x" * 200)
        Path(self.manifest[3]).write_text("y" * 200)
        groups = [self.manifest[:2], [self.manifest[1]], [self.manifest[2]], [self.manifest[3]]]
        batches, count, size = b.pack(self.manifest, groups)
        self.assertEqual([indices for indices, _ in batches], [[0, 1], [2], [3]])
        self.assertEqual((count, size), (2, 200))

    def test_full_group_context_mapping_objects_and_duplicates(self):
        row = dict(file=self.manifest[1], line=1, column=1, endLine=1, endColumn=2,
                   code=2086, level="warning", message="not logged", fix={"replacements": []})
        # Context-only diagnostics must be compared even for a clean target.
        target = next(r for r in self.records if r["type"] == "target")
        target["group_diagnostics"] = [row, row]
        target["measurement"].update(stdout=json.dumps([row, row]), status=1)
        self.save()
        self.assertEqual(self.run_experiment()["parity"], "non_parity")
        self.assertNotEqual(b.multiset([row, row]), b.multiset([row]))
        changed = copy.deepcopy(row)
        changed["fix"]["replacements"] = [{"newText": "different"}]
        self.assertNotEqual(b.multiset([row]), b.multiset([changed]))
        # Target diagnostics and status must be validated, not trusted.
        target["target_diagnostics"] = [row]
        self.save()
        self.assertEqual(self.run_experiment()["parity"], "inconclusive")

    def test_measure_exception_counts_attempt_and_has_unknown_totals(self):
        original = b.c.measure

        def fail_batch(command, **kwargs):
            if command == [str(self.cli), "--version"]:
                return original(command, **kwargs)
            raise OSError("measurement unavailable")

        with mock.patch.object(b.c, "measure", side_effect=fail_batch):
            result = self.run_experiment()
        self.assertEqual((result["parity"], result["batch_calls"]), ("inconclusive", 1))
        self.assertIsNone(result["batch_elapsed_s"])
        self.assertIsNone(result["batch_peak_rss_kib"])

    def test_malformed_baseline_never_starts_children(self):
        pristine = copy.deepcopy(self.records)
        mutations = [("target_start", "group_count", 999), ("target_start", "target", "wrong"),
                     ("target", "status", 1), ("target", "group", []),
                     ("summary", "complete", False), ("summary", "status", 1)]
        for kind, key, value in mutations:
            with self.subTest(kind=kind, key=key):
                self.records = copy.deepcopy(pristine)
                next(r for r in self.records if r["type"] == kind)[key] = value
                self.save()
                self.assertEqual(self.run_experiment()["parity"], "inconclusive")
        self.assertEqual(self.calls.read_text(), "")

    def test_fail_closed_child_and_input_errors(self):
        for body in ('print("[]"); sys.exit(3)', 'print("[]"); sys.exit(1)',
                     'print("[]"); print("private", file=sys.stderr)',
                     'print("not JSON")', 'print("{}")', 'print("[NaN]")',
                     'print(json.dumps([{"file": "outside"}]))'):
            with self.subTest(body=body):
                self.script(body)
                self.assertEqual(self.run_experiment()["parity"], "inconclusive")
        row = dict(file=self.manifest[0], line=1, column=1, endLine=1, endColumn=2,
                   level="warning", code=2086, message="not logged")
        self.script(f'if {self.manifest[2]!r} in sys.argv: sys.exit(3)\n'
                    f'print(json.dumps([{row!r}])); sys.exit(1)')
        result = self.run_experiment()
        self.assertEqual((result["parity"], result["batch_calls"]), ("inconclusive", 2))
        self.assertIsNone(result["batch_elapsed_s"])
        self.assertIsNone(result["batch_peak_rss_kib"])
        self.script('time.sleep(2)')
        # Use the same configured bounds for baseline and experiment.
        self.records[0]["limits"]["child_timeout_s"] = 0.1
        self.save()
        with mock.patch.dict(os.environ, {c.TIMEOUT_ENV: "0.1"}):
            self.assertEqual(self.run_experiment()["parity"], "inconclusive")
        self.records[0]["limits"] = dict(stream_bytes=100, child_timeout_s=c.TIMEOUT)
        self.save()
        self.script('print("x" * 1000)')
        with mock.patch.dict(os.environ, {c.OUTPUT_CAP_ENV: "100"}):
            self.assertEqual(self.run_experiment()["parity"], "inconclusive")
        for key, value in ((b.REPORT_CAP_ENV, "10"), (c.TIMEOUT_ENV, "nan"),
                           (c.OUTPUT_CAP_ENV, "0")):
            with mock.patch.dict(os.environ, {key: value}):
                self.assertEqual(self.run_experiment()["parity"], "inconclusive")
        self.path.write_text('{"type":"header","type":"summary"}\n')
        self.assertEqual(self.run_experiment()["parity"], "inconclusive")
        # CLI failure output is still one sanitized JSON object, never raw data.
        result = subprocess.run([sys.executable, str(Path(b.__file__)), str(self.path), str(self.cli)],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual((result.returncode, result.stderr), (0, ""))
        summary = json.loads(result.stdout)
        self.assertEqual(summary["parity"], "inconclusive")
        self.assertTrue(all(k == "parity" or v is None or type(v) in (int, float)
                            for k, v in summary.items()))


if __name__ == "__main__":
    unittest.main()
