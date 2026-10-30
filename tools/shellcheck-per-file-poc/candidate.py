#!/usr/bin/env python3
"""Test-only direct-source-context ShellCheck candidate; no workflow integration."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
PIN = "0.11.0"
# Per stream, per invocation. Overflow is an explicit incomplete/failing result.
OUTPUT_CAP = 8 * 1024 * 1024
TIMEOUT = 300


def measure(command, *, cwd=ROOT, cap=OUTPUT_CAP, timeout=TIMEOUT):
    """Drain bounded pipes and reap this PID with wait4 (not cumulative rusage)."""
    started = time.monotonic()
    result = dict(command=list(map(str, command)), status=None, elapsed_s=None,
                  peak_rss_kib=None, stdout="", stderr="", errors=[])
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    proc = None
    try:
        proc = subprocess.Popen(result["command"], cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
        with selectors.DefaultSelector() as selector:
            for name in buffers:
                stream = getattr(proc, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            reaped = False
            killed = False
            while selector.get_map() or not reaped:
                if not killed and time.monotonic() - started > timeout:
                    result["errors"].append("timeout")
                    os.killpg(proc.pid, signal.SIGKILL)
                    killed = True
                for key, _ in selector.select(0.02):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    buf = buffers[key.data]
                    room = cap - len(buf)
                    buf.extend(chunk[:room])
                    if len(chunk) > room:
                        error = key.data + " exceeds byte cap; retained prefix only"
                        if error not in result["errors"]:
                            result["errors"].append(error)
                        if not killed:
                            os.killpg(proc.pid, signal.SIGKILL)
                            killed = True
                if not reaped:
                    pid, status, usage = os.wait4(proc.pid, os.WNOHANG)
                    if pid:
                        proc.returncode = os.waitstatus_to_exitcode(status)
                        result["status"] = proc.returncode
                        result["peak_rss_kib"] = (usage.ru_maxrss / 1024 if
                                                   sys.platform == "darwin" else usage.ru_maxrss)
                        reaped = True
    except Exception as exc:
        result["errors"].append(f"wrapper failure: {type(exc).__name__}: {exc}")
    finally:
        if proc is not None:
            if proc.returncode is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                _, status, usage = os.wait4(proc.pid, 0)
                proc.returncode = os.waitstatus_to_exitcode(status)
                result["status"] = proc.returncode
                result["peak_rss_kib"] = (usage.ru_maxrss / 1024 if
                                           sys.platform == "darwin" else usage.ru_maxrss)
            for stream in (proc.stdout, proc.stderr):
                stream.close()
        for name, data in buffers.items():
            try:
                result[name] = data.decode("utf-8")
            except UnicodeDecodeError:
                # Lossless byte evidence; never let replacement decoding pass.
                result[name] = data.decode("utf-8", "backslashreplace")
                result[name + "_hex"] = data.hex()
                result["errors"].append(name + " is not UTF-8")
        result["elapsed_s"] = time.monotonic() - started
    return result


def canonical(path):
    path = Path(path)
    return str((ROOT / path).resolve())


def production_manifest():
    """Same path list/order/globs as tests/test_shellcheck.sh; tested for drift."""
    paths = ["lmline/lmline", "lmline/engine", "lmline/validate"]
    paths += sorted(str(p.relative_to(ROOT)) for p in (ROOT / "lmline").glob("*.bash"))
    paths += ["lmline/completions/lmline.bash", "install.sh", "scripts/install-shellcheck.sh",
              "scripts/check-commit-subjects.sh", "scripts/privacy-scan.sh", "scripts/publish-check.sh"]
    paths += sorted(str(p.relative_to(ROOT)) for p in (ROOT / "tests").glob("*.sh"))
    return paths


def sources(target, manifest):
    """Resolve literal annotated sources against repo cwd, never add external files.

    No recursive closure: only annotations physically present in this target.
    Non-manifest declarations (including /dev/null) are counted but not added.
    """
    declarations = []
    for line_number, line in enumerate(Path(target).read_text().splitlines(), 1):
        match = re.match(r"^\s*#\s*shellcheck\s+(.*)$", line)
        if match and re.search(r"\bsource=", match[1]):
            for token in shlex.split(match[1], comments=True):
                if token.startswith("source="):
                    value = token[len("source="):]
                    resolved = canonical(value)
                    declarations.append(dict(line=line_number, source=value, resolved=resolved,
                                             in_manifest=resolved in manifest))
    return declarations


def run(files, shellcheck="shellcheck", *, rcfile=None, cap=OUTPUT_CAP, timeout=TIMEOUT,
        record=None):
    """Return the full report; optionally emit completed evidence records.

    rcfile is a fixture-only hook; neither command-line runner exposes it.
    Sink failures propagate, never become tool errors or a successful summary.
    """
    def emit(kind, data):
        if record is not None:
            record(dict(type=kind, **data))

    started = time.monotonic()
    report = dict(schema=1, cwd=str(ROOT), arguments=list(map(str, files)), manifest=[],
                  limits=dict(stream_bytes=cap, child_timeout_s=timeout),
                  version=None, targets=[], errors=[], target_diagnostics=[])
    path_errors = {}
    for index, path in enumerate(files):
        try:
            report["manifest"].append(canonical(path))
        except (OSError, RuntimeError, ValueError) as exc:
            # Preserve the occurrence and attempt its CLI group even when path
            # canonicalization fails; never abandon the remaining inputs.
            report["manifest"].append(os.path.abspath(ROOT / path))
            path_errors[index] = f"path resolution failure: {exc}"
    emit("header", {key: report[key] for key in ("schema", "cwd", "arguments", "manifest", "limits")})
    try:
        if not files:
            raise ValueError("empty manifest")
        version = measure([shellcheck, "--version"], cap=cap, timeout=timeout)
        report["version"] = version
        if (version["errors"] or version["status"] != 0 or version["stderr"] or
                not re.search(r"^version: " + re.escape(PIN) + r"$", version["stdout"], re.M)):
            report["errors"].append("pinned ShellCheck version check failed")
    except Exception as exc:
        report["errors"].append(f"setup failure: {type(exc).__name__}: {exc}")
    emit("version", dict(version=report["version"], errors=report["errors"]))
    manifest = report["manifest"]
    members = set(manifest)
    for index, target in enumerate(manifest):
        entry = dict(index=index, target=target, sources=[], group=[], measurement=None,
                     group_diagnostics=None, target_diagnostics=[], errors=[])
        report["targets"].append(entry)
        if index in path_errors:
            entry["errors"].append(path_errors[index])
        try:
            try:
                entry["sources"] = sources(target, members)
            except Exception as exc:
                entry["errors"].append(f"source resolution failure: {type(exc).__name__}: {exc}")
            wanted = {target} | {d["resolved"] for d in entry["sources"] if d["in_manifest"]}
            # Keep manifest order, including when dependencies precede the target.
            entry["group"] = list(dict.fromkeys(p for p in manifest if p in wanted))
            command = [shellcheck, "-s", "bash", "--format=json"]
            if rcfile is not None:
                command += ["--rcfile=" + str(rcfile)]
            command += entry["group"]
            measured = measure(command, cap=cap, timeout=timeout)
            entry["measurement"] = measured
            entry["errors"].extend(measured["errors"])
            if measured["status"] not in (0, 1):
                entry["errors"].append("tool/resource failure: status is not 0/1")
            if measured["stderr"]:
                entry["errors"].append("unexpected stderr")
            try:
                def reject_constant(value):
                    raise ValueError("non-JSON constant: " + value)
                rows = json.loads(measured["stdout"], parse_constant=reject_constant)
                required = {"file", "line", "column", "endLine", "endColumn", "level", "code", "message"}
                if not isinstance(rows, list) or any(
                        not isinstance(row, dict) or not required <= row.keys() or
                        row["file"] not in entry["group"] for row in rows):
                    raise ValueError("unexpected diagnostic shape/path")
                entry["group_diagnostics"] = rows
                entry["target_diagnostics"] = [row for row in rows if row["file"] == target]
                if measured["status"] in (0, 1) and measured["status"] != int(bool(rows)):
                    entry["errors"].append("group status disagrees with diagnostics")
            except (ValueError, TypeError) as exc:
                entry["errors"].append(f"invalid JSON diagnostics: {exc}")
        except Exception as exc:
            entry["errors"].append(f"target wrapper failure: {type(exc).__name__}: {exc}")
        report["target_diagnostics"].extend(entry["target_diagnostics"])
        entry["status"] = 2 if entry["errors"] else int(bool(entry["target_diagnostics"]))
        emit("target", entry)
    declarations = [d for t in report["targets"] for d in t["sources"]]
    report["source_counts"] = dict(
        declarations=len(declarations), in_manifest=sum(d["in_manifest"] for d in declarations),
        outside_manifest=sum(not d["in_manifest"] for d in declarations),
        unique_direct_edges=len({(t["target"], d["resolved"]) for t in report["targets"] for d in t["sources"]}),
        max_group_size=max((len(t["group"]) for t in report["targets"]), default=0))
    report["status"] = (2 if report["errors"] or any(t["errors"] for t in report["targets"])
                        else int(bool(report["target_diagnostics"])))
    report["complete"] = report["status"] != 2
    report["total_elapsed_s"] = time.monotonic() - started
    emit("summary", {key: report[key] for key in
                     ("status", "complete", "source_counts", "errors", "total_elapsed_s")})
    return report


def main(manifest=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--shellcheck", default="shellcheck", help="pinned CLI path (version checked)")
    if manifest is None:
        parser.add_argument("files", nargs="+")
    parser.add_argument("--timeout", type=float, default=TIMEOUT, help="seconds per child (default: 300)")
    parser.add_argument("--output-cap", type=int, default=OUTPUT_CAP,
                        help="bytes per child stream (default: 8388608)")
    args = parser.parse_args()
    if not 0 < args.timeout < float("inf") or args.output_cap < 1:
        parser.error("timeout must be finite and positive; output cap must be positive")
    try:
        # Exclusive creation prevents overwriting a source/rc or stale evidence.
        with args.report.open("x") as stream:
            def record(data):
                stream.write(json.dumps(data, ensure_ascii=True, allow_nan=False) + "\n")
                stream.flush()
            report = run(manifest if manifest is not None else args.files, args.shellcheck,
                         cap=args.output_cap, timeout=args.timeout, record=record)
    except (OSError, ValueError) as exc:
        print(f"evidence report failure: {exc}", file=sys.stderr)
        return 2
    return report["status"]


if __name__ == "__main__":
    sys.exit(main())
