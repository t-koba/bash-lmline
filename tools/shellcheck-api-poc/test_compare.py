#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic evidence only: no ShellCheck executable or compiler required."""
import copy
import json
import pathlib
import tempfile
import unittest

from compare import compare


def baseline():
    return [{"file": "tests/test_endpoint_display.sh", "line": line,
             "column": 3, "endLine": line, "endColumn": 20,
             "code": 1091, "level": "info", "message": "Not following source"}
            for line in (3, 41, 82, 179)]


class CompareTests(unittest.TestCase):
    def check(self, cli, api, *, statuses=(1, 1)):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for name, rows, status in zip(("cli", "api"), (cli, api), statuses):
                (root / f"{name}.json").write_text(json.dumps(rows))
                (root / f"{name}.status").write_text(str(status))
                (root / f"{name}.stderr").write_text("")
                (root / f"{name}.time").write_text(
                    f"elapsed_s=1.0\npeak_rss_kib=100\nexit_status={status}\n")
            return compare(root)

    def test_expected_nonempty_match(self):
        cli = baseline()
        cli[0]["fix"] = {"replacements": []}  # Not analyzer diagnostics.
        message, same = self.check(cli, list(reversed(baseline())))
        self.assertTrue(same)
        self.assertEqual(message, "One-file nonempty diagnostic and exit-status parity.")

    def test_empty_match_fails_closed(self):
        self.assertFalse(self.check([], [], statuses=(0, 0))[1])

    def test_each_expected_diagnostic_required_in_both_outputs(self):
        for index in range(4):
            missing = baseline()
            del missing[index]
            for cli, api in ((missing, baseline()), (baseline(), missing),
                             (missing, missing)):
                with self.subTest(index=index, cli=cli, api=api):
                    message, same = self.check(cli, api)
                    self.assertFalse(same)
                    self.assertIn("lacks expected nonempty diagnostics", message)

    def test_wrong_expected_identity_fails_even_when_outputs_match(self):
        for key, value in (("file", "other.sh"), ("line", 4),
                           ("code", 1090), ("level", "warning")):
            rows = baseline()
            rows[0][key] = value
            with self.subTest(key=key):
                self.assertFalse(self.check(rows, rows)[1])

    def test_complete_diagnostic_fields_still_compared(self):
        for key, value in (("column", 4), ("endLine", 4), ("endColumn", 21),
                           ("message", "Different source message")):
            api = baseline()
            api[0][key] = value
            with self.subTest(key=key):
                message, same = self.check(baseline(), api)
                self.assertFalse(same)
                self.assertIn("Mismatch", message)

    def test_additional_diagnostics_and_duplicate_multiplicity(self):
        for extra in (baseline()[0], dict(baseline()[0], code=9999)):
            cli = baseline() + [extra]
            with self.subTest(extra=extra):
                self.assertTrue(self.check(cli, copy.deepcopy(cli))[1])
                self.assertFalse(self.check(cli, baseline())[1])
                self.assertFalse(self.check(baseline(), cli)[1])

    def test_invalid_or_mismatched_statuses_fail(self):
        for statuses in ((0, 1), (1, 0), (0, 0), (137, 137), (1, 124)):
            with self.subTest(statuses=statuses):
                self.assertFalse(self.check(baseline(), baseline(), statuses=statuses)[1])


if __name__ == "__main__":
    unittest.main()
