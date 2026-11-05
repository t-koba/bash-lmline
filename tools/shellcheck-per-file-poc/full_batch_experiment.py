#!/usr/bin/env python3
"""One-off diagnostic only: compare bounded batches with completed JSONL evidence."""
from collections import Counter
import json
import math
import os
from pathlib import Path
import sys

import candidate as c

REPORT_CAP_ENV = "LMLINE_SHELLCHECK_BATCH_REPORT_CAP_BYTES"
REPORT_CAP = 256 * 1024 * 1024


def require(condition):
    if not condition:
        raise ValueError("inconclusive")


def number(value, positive=False):
    require(type(value) in (int, float) and math.isfinite(value)
            and (value > 0 if positive else value >= 0))
    return value


def decode(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result)
            result[key] = value
        return result

    def constant(_value):
        raise ValueError("non-JSON")
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def multiset(rows):
    return Counter(json.dumps(row, sort_keys=True, allow_nan=False) for row in rows)


def diagnostics(rows, group):
    required = {"file", "line", "column", "endLine", "endColumn", "level", "code", "message"}
    require(type(rows) is list)
    for row in rows:
        require(type(row) is dict and required <= row.keys() and row["file"] in group)
        require(all(type(row[k]) is int and row[k] >= 0
                    for k in ("line", "column", "endLine", "endColumn", "code")))
        require(row["level"] in ("error", "warning", "info", "style")
                and type(row["message"]) is str)
    multiset(rows)  # Also reject non-finite values anywhere in an object/fix.
    return rows


def measurement(measured, command):
    require(measured["command"] == command and measured["errors"] == []
            and measured["stderr"] == "" and type(measured["status"]) is int)
    number(measured["elapsed_s"])
    number(measured["peak_rss_kib"], positive=True)


def lint_rows(measured, command, group):
    measurement(measured, command)
    rows = diagnostics(decode(measured["stdout"]), group)
    require(measured["status"] == int(bool(rows)))
    return rows


def pack(manifest, groups):
    """Greedy manifest order; bounds are the largest existing direct groups."""
    sizes = {p: Path(p).stat().st_size for p in manifest}
    max_count = max(map(len, groups))
    max_bytes = max(sum(sizes[p] for p in group) for group in groups)
    batches, targets, union = [], [], set()
    for index, group in enumerate(groups):
        wanted = union | set(group)
        if len(wanted) > max_count or sum(sizes[p] for p in wanted) > max_bytes:
            require(bool(targets))
            batches.append((targets, [p for p in manifest if p in union]))
            targets, union = [], set()
        targets.append(index)
        union.update(group)
        require(len(union) <= max_count and sum(sizes[p] for p in union) <= max_bytes)
    if targets:
        batches.append((targets, [p for p in manifest if p in union]))
    return batches, max_count, max_bytes


def compare(path, shellcheck, manifest, result, *, cap, timeout, report_cap):
    require(type(cap) is int and cap > 0 and type(report_cap) is int and report_cap > 0)
    number(timeout, positive=True)
    require(manifest and len(set(manifest)) == len(manifest))
    with Path(path).open("rb") as stream:
        raw = stream.read(report_cap + 1)
    require(len(raw) <= report_cap and raw.endswith(b"\n"))
    records = [decode(line) for line in raw.decode("utf-8").splitlines()]
    require(all(type(r) is dict for r in records))
    # Only accept a complete, ordered runner report, not concatenated/stale data.
    kinds = [r["type"] for r in records]
    require(kinds[:2] == ["header", "version"] and kinds[-1:] == ["summary"])
    require(kinds.count("header") == kinds.count("version") == kinds.count("summary") == 1)
    header, version, summary = records[0], records[1], records[-1]
    require(type(header["schema"]) is int and header["schema"] == 1 and header["cwd"] == str(c.ROOT)
            and header["manifest"] == manifest
            and list(map(c.canonical, header["arguments"])) == manifest
            and header["limits"] == dict(stream_bytes=cap, child_timeout_s=timeout))
    require(version["errors"] == [] and summary["errors"] == []
            and summary["complete"] is True and type(summary["status"]) is int
            and summary["status"] == 0)
    measurement(version["version"], [shellcheck, "--version"])
    require(version["version"]["status"] == 0
            and f"version: {c.PIN}" in version["version"]["stdout"].splitlines())
    number(summary["total_elapsed_s"])
    entries = []
    starts = []
    pending = None
    for record in records[2:-1]:
        kind = record["type"]
        if kind == "target_start":
            require(pending is None and type(record["index"]) is int and record["index"] == len(entries))
            pending = record
        elif kind == "resource_sample":
            # This one-off comparison measures the normal unguarded route only.
            raise ValueError("guarded baseline")
        else:
            require(kind == "target" and pending is not None)
            require(record["index"] == pending["index"] == len(entries))
            entries.append(record)
            starts.append(pending)
            pending = None
    require(pending is None and len(entries) == len(manifest))
    groups = []
    for index, (target, entry) in enumerate(zip(manifest, entries)):
        declarations = c.sources(target, set(manifest))
        wanted = {target} | {d["resolved"] for d in declarations if d["in_manifest"]}
        group = [p for p in manifest if p in wanted]
        require(type(entry["index"]) is int and entry["index"] == index and entry["target"] == target
                and starts[index]["target"] == c.relative_target(target)
                and type(starts[index]["group_count"]) is int and starts[index]["group_count"] == len(group)
                and entry["sources"] == declarations and entry["group"] == group
                and entry["errors"] == [])
        rows = lint_rows(entry["measurement"], [shellcheck, "-s", "bash", "--format=json"] + group, group)
        target_rows = [r for r in rows if r["file"] == target]
        require(multiset(rows) == multiset(diagnostics(entry["group_diagnostics"], group))
                and multiset(target_rows) == multiset(diagnostics(entry["target_diagnostics"], [target]))
                and type(entry["status"]) is int and entry["status"] == int(bool(target_rows)))
        groups.append(group)
    declarations = [d for e in entries for d in e["sources"]]
    require(summary["source_counts"] == dict(
        declarations=len(declarations), in_manifest=sum(d["in_manifest"] for d in declarations),
        outside_manifest=sum(not d["in_manifest"] for d in declarations),
        unique_direct_edges=len({(e["target"], d["resolved"]) for e in entries for d in e["sources"]}),
        max_group_size=max(map(len, groups))))
    require(not any(e["status"] for e in entries))  # Authoritative success only.
    result.update(target_count=len(entries),
                  baseline_elapsed_s=number(sum(e["measurement"]["elapsed_s"] for e in entries)),
                  baseline_peak_rss_kib=max(e["measurement"]["peak_rss_kib"] for e in entries))
    batches, count, size = pack(manifest, groups)
    result.update(batch_count=len(batches), max_group_files=count, max_group_bytes=size)
    measured = c.measure([shellcheck, "--version"], cap=cap, timeout=timeout)
    measurement(measured, [shellcheck, "--version"])
    require(measured["status"] == 0 and f"version: {c.PIN}" in measured["stdout"].splitlines())
    elapsed, rss, parity = 0, 0, True
    for indices, union in batches:
        command = [shellcheck, "-s", "bash", "--format=json"] + union
        # Count attempts even if process creation or measurement raises.
        result["batch_calls"] += 1
        measured = c.measure(command, cap=cap, timeout=timeout)
        elapsed = number(elapsed + number(measured["elapsed_s"]))
        rss = max(rss, number(measured["peak_rss_kib"], positive=True))
        rows = lint_rows(measured, command, union)
        for index in indices:
            entry = entries[index]
            group_rows = [r for r in rows if r["file"] in groups[index]]
            target_rows = [r for r in group_rows if r["file"] == manifest[index]]
            parity &= (multiset(group_rows) == multiset(entry["group_diagnostics"])
                       and multiset(target_rows) == multiset(entry["target_diagnostics"])
                       and int(bool(group_rows)) == entry["measurement"]["status"]
                       and int(bool(target_rows)) == entry["status"])
    result.update(batch_elapsed_s=number(elapsed), batch_peak_rss_kib=rss,
                  parity="parity" if parity else "non_parity")


def experiment(path, shellcheck, manifest=None):
    result = dict(target_count=0, batch_count=0, batch_calls=0,
                  max_group_files=None, max_group_bytes=None,
                  baseline_elapsed_s=None, baseline_peak_rss_kib=None,
                  batch_elapsed_s=None, batch_peak_rss_kib=None, parity="inconclusive")
    try:
        compare(path, shellcheck, list(map(c.canonical, c.production_manifest())) if manifest is None else manifest,
                result, cap=int(os.environ.get(c.OUTPUT_CAP_ENV, c.OUTPUT_CAP)),
                timeout=float(os.environ.get(c.TIMEOUT_ENV, c.TIMEOUT)),
                report_cap=int(os.environ.get(REPORT_CAP_ENV, REPORT_CAP)))
    except Exception:
        result["parity"] = "inconclusive"
    return result


if __name__ == "__main__":
    # The shell harness supplies exactly these two arguments; never print child
    # output, exceptions, paths or argparse usage, even for malformed input.
    report, cli = sys.argv[1:] if len(sys.argv) == 3 else (None, None)
    print(json.dumps(experiment(report, cli), allow_nan=False, sort_keys=True))
