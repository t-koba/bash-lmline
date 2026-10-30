#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare diagnostic multisets, never equate a resource failure with parity."""
import json
import pathlib
import math
import sys

KEYS = ("file", "line", "column", "endLine", "endColumn", "level", "code", "message")
EXPECTED = {("tests/test_endpoint_display.sh", line, 1091, "info")
            for line in (3, 41, 82, 179)}
ARTIFACT_CAP = 8 * 1024 * 1024


def compare(root):
    statuses = [int((root / f"{name}.status").read_text()) for name in ("cli", "api")]
    if any(status not in (0, 1) for status in statuses):
        return "Incomplete: command failure or resource limit; no parity claim.", False
    for name, status in zip(("cli", "api"), statuses):
        metrics = dict(line.split("=", 1) for line in
                       (root / f"{name}.time").read_text().splitlines() if "=" in line)
        elapsed = float(metrics["elapsed_s"])
        if (int(metrics["exit_status"]) != status or
                not math.isfinite(elapsed) or elapsed < 0 or
                int(metrics["peak_rss_kib"]) <= 0):
            return "Incomplete: invalid resource evidence; no parity claim.", False
    for name in ("cli", "api"):
        for ext in (".json", ".stderr"):
            if (root / f"{name}{ext}").stat().st_size > ARTIFACT_CAP:
                return "Incomplete: raw evidence over artifact cap; no parity claim.", False
    diagnostics = []
    for name, status in zip(("cli", "api"), statuses):
        if (root / f"{name}.stderr").read_bytes():
            return "Incomplete: unexpected stderr; no parity claim.", False
        rows = json.loads((root / f"{name}.json").read_text())
        if not isinstance(rows, list) or status != int(bool(rows)):
            return "Incomplete: invalid diagnostics/status; no parity claim.", False
        identities = {(row["file"], row["line"], row["code"], row["level"])
                      for row in rows}
        if not EXPECTED <= identities:
            return f"Incomplete: {name} lacks expected nonempty diagnostics; no parity claim.", False
        # Preserve duplicate multiplicity, every diagnostic, and all diagnostic
        # fields. CLI's optional suggested-edit ('fix') metadata is retained in
        # cli.json but is not diagnostic parity (the API tool proposes no edits).
        diagnostics.append(sorted(json.dumps({k: row[k] for k in KEYS},
                                              sort_keys=True) for row in rows))
    same = statuses[0] == statuses[1] and diagnostics[0] == diagnostics[1]
    return ("One-file nonempty diagnostic and exit-status parity." if same else
            "Mismatch: diagnostics or exit statuses differ; no parity claim."), same


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1])
    try:
        message, same = compare(root)
    except (OSError, ValueError, KeyError, TypeError):
        message, same = "Incomplete: missing/malformed evidence; no parity claim.", False
    (root / "comparison.txt").write_text(message + "\n")
    print(message)
    sys.exit(0 if same else 1)
