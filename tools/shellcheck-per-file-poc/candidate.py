#!/usr/bin/env python3
"""Test-only direct-source-context ShellCheck candidate with opt-in CI diagnostics."""
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
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PIN = "0.11.0"
# Per stream, per invocation. Overflow is an explicit incomplete/failing result.
OUTPUT_CAP = 8 * 1024 * 1024
TIMEOUT = 300
# Fixed-size, allowlisted log records; the JSONL evidence has no such reduction.
PROGRESS_BYTES = 1024
SAMPLE_INTERVAL = 0.1
SAMPLE_COUNT = 4096
SAMPLE_BYTES = 1024 * 1024
QUIESCE_SECONDS = 1.0
COUNTERS = ("memory_current", "memory_peak", "oom", "oom_kill", "cpu_usage_usec")


def relative_target(value):
    try:
        target = Path(value).resolve().relative_to(ROOT).as_posix()
    except (OSError, RuntimeError, ValueError):
        raise ValueError("unrepresentable progress target") from None
    if target == "." or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in target):
        raise ValueError("unrepresentable progress target")
    return target


class CgroupGuard:
    """One disposable cgroup per invocation; never use parent process accounting.

    This runner is single-threaded: preexec_fn writes the forked child's own
    PID into the leaf before exec, and Popen's error pipe makes placement
    failure a no-exec failure. No delegation or controller activation is
    performed on the supplied parent.
    """
    def __init__(self, config):
        self.config = config
        self.path = None

    def setup(self):
        for key in ("memory_bytes", "cpu_usec", "cpu_quota_usec", "cpu_period_usec"):
            if type(self.config[key]) is not int or not 0 < self.config[key] < 2**63:
                raise ValueError("guard budgets must be explicit finite positive integers")
        parent = Path(self.config["parent"])
        if not parent.is_absolute() or parent.resolve() != parent:
            raise ValueError("cgroup parent must be an absolute canonical path")
        # Controller-shaped ordinary directories are not sufficient evidence.
        mounts = []
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            left, right = line.split(" - ", 1)
            mount = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), left.split()[4])
            mount = Path(mount)
            if parent == mount or mount in parent.parents:
                mounts.append((mount, right.split()[0]))
        if not mounts or max(mounts, key=lambda item: len(item[0].parts))[1] != "cgroup2":
            raise ValueError("parent is not on a cgroup-v2 mount")
        for name in ("cgroup.controllers", "cgroup.subtree_control"):
            if not {"memory", "cpu"} <= set((parent / name).read_text().split()):
                raise ValueError("memory/cpu controllers must already be delegated")
        self.path = Path(tempfile.mkdtemp(prefix="shellcheck-", dir=parent))
        for name in ("cgroup.procs", "cgroup.events", "cgroup.kill", "memory.max",
                     "memory.current", "memory.peak", "memory.events", "cpu.max", "cpu.stat"):
            if not (self.path / name).is_file():
                raise ValueError("required cgroup-v2 file missing: " + name)
        (self.path / "memory.max").write_text(str(self.config["memory_bytes"]))
        if (self.path / "memory.max").read_text().strip() != str(self.config["memory_bytes"]):
            raise ValueError("memory limit readback failed")
        quota = str(self.config["cpu_quota_usec"]) + " " + str(self.config["cpu_period_usec"])
        (self.path / "cpu.max").write_text(quota)
        if (self.path / "cpu.max").read_text().strip() != quota:
            raise ValueError("cpu limit readback failed")
        with (self.path / "cgroup.kill").open("w"):
            pass

    def place(self):
        # Runs in the forked child before exec: join with this child's own PID.
        # Writing "0" would be invalid in a cgroup-v2 leaf; the kernel requires
        # an explicit PID. Callers must not substitute the parent PID.
        pid = str(os.getpid())
        (self.path / "cgroup.procs").write_text(pid)
        if pid not in (self.path / "cgroup.procs").read_text().split():
            raise ValueError("cgroup placement readback failed")

    def sample(self):
        def number(file, key=None):
            try:
                text = (self.path / file).read_text()
                if key is not None:
                    text = dict(line.split() for line in text.splitlines())[key]
                value = int(text.strip())
                return value if value >= 0 else "unavailable"
            except (OSError, ValueError, KeyError):
                return "unavailable"
        return dict(memory_current=number("memory.current"), memory_peak=number("memory.peak"),
                    oom=number("memory.events", "oom"),
                    oom_kill=number("memory.events", "oom_kill"),
                    cpu_usage_usec=number("cpu.stat", "usage_usec"))

    def kill(self):
        if self.path is not None:
            (self.path / "cgroup.kill").write_text("1")

    def cleanup(self, final_capture):
        # Caller must pass a non-enforcing final capture: limit/observer/cap
        # breaches are recorded as errors by the caller but must not block
        # removal of a proven-empty leaf. Only unknown quiescence, readback
        # failure, or removal failure keeps the leaf reserved.
        if self.path is None:
            return dict(quiescent=True, removed=True)
        # Even a normally exited leader can have surviving descendants.
        self.kill()
        deadline = time.monotonic() + QUIESCE_SECONDS
        while True:
            events = dict(line.split() for line in (self.path / "cgroup.events").read_text().splitlines())
            if events.get("populated") == "0":
                final_capture()
                self.path.rmdir()
                return dict(quiescent=True, removed=True)
            if events.get("populated") != "1" or time.monotonic() >= deadline:
                raise ValueError("cgroup quiescence unknown; reserved, not removed")
            time.sleep(0.02)



def progress_record(record):
    """Project evidence onto log-safe scalars, never child text or commands."""
    kind = record["type"]
    data = dict(type=kind, schema=1)
    if kind == "header":
        data["target_count"] = len(record["manifest"])
    elif kind == "version":
        data.update(pinned_version=PIN, status=2 if record["errors"] else 0)
    elif kind == "target_start":
        data.update(index=record["index"], target=relative_target(ROOT / record["target"]),
                    group_count=record["group_count"])
        if type(data["index"]) is not int or data["index"] < 0 or type(data["group_count"]) is not int or data["group_count"] < 1:
            raise ValueError("invalid target start")
    elif kind == "resource_sample":
        data.update(index=record["index"], sample=record["sample"])
        if type(data["index"]) is not int or data["index"] < -1 or type(data["sample"]) is not int or not 0 <= data["sample"] < SAMPLE_COUNT:
            raise ValueError("invalid sample identity")
        for key in COUNTERS:
            value = record[key]
            if value != "unavailable" and (type(value) is not int or not 0 <= value < 2**64):
                raise ValueError("invalid resource counter")
            data[key] = value
    elif kind == "target":
        target = relative_target(record["target"])
        measurement = record["measurement"] or {}
        data.update(index=record["index"], target=target, status=record["status"],
                    tool_status=measurement.get("status"),
                    elapsed_s=measurement.get("elapsed_s"),
                    peak_rss_kib=measurement.get("peak_rss_kib"),
                    target_diagnostic_count=len(record["target_diagnostics"]),
                    error_count=len(record["errors"]))
    elif kind == "summary":
        data.update(status=record["status"], complete=record["complete"],
                    total_elapsed_s=record["total_elapsed_s"])
    else:
        raise ValueError("unknown progress record")
    line = json.dumps(data, ensure_ascii=True, allow_nan=False) + "\n"
    if len(line.encode("ascii")) > PROGRESS_BYTES:
        raise ValueError("unrepresentable progress record")
    return line


def measure(command, *, cwd=ROOT, cap=OUTPUT_CAP, timeout=TIMEOUT, guard=None,
            observe=None, index=-1):
    """Drain bounded pipes and reap this PID with wait4 (not cumulative rusage).

    With the optional guard, SIGTERM/SIGINT while a child is active trigger
    bounded synchronous kill/reap/quiescence and are reported as incomplete
    status 2 with the original child outcome preserved; the leaf is still
    removed when authoritative quiescence is proven. SIGKILL cannot be
    handled in-process and may leave a reserved leaf for independent cleanup.
    """
    started = time.monotonic()
    result = dict(command=list(map(str, command)), status=None, elapsed_s=None,
                  peak_rss_kib=None, stdout="", stderr="", errors=[])
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    proc = None
    resource = CgroupGuard(guard) if guard is not None else None
    next_sample = started
    sample_bytes = 0
    terminated = []
    installed = False
    handler_error = False
    old_term = old_int = None
    if resource is not None:
        result["guard"] = dict(samples=[], cleanup=None, path=None, limits=dict(guard),
                               sample_interval_s=SAMPLE_INTERVAL, sample_count_cap=SAMPLE_COUNT,
                               sample_byte_cap=SAMPLE_BYTES)
        result["terminated_by_signal"] = None
        try:
            old_term = signal.getsignal(signal.SIGTERM)
            old_int = signal.getsignal(signal.SIGINT)
            def _on_signal(signum, frame):
                terminated.append(signum)
            signal.signal(signal.SIGTERM, _on_signal)
            signal.signal(signal.SIGINT, _on_signal)
            installed = True
        except ValueError:
            # Guarded cleanup depends on catching termination in this thread.
            # A library caller outside the main thread fails closed, never runs
            # a detached child without its bounded signal cleanup.
            installed = False
            handler_error = True

    def enforce_sample():
        nonlocal sample_bytes, next_sample
        samples = result["guard"]["samples"]
        if len(samples) >= SAMPLE_COUNT:
            raise ValueError("resource sample count cap")
        values = resource.sample()
        row = dict(type="resource_sample", index=index, sample=len(samples),
                   **{k: values.get(k, "unavailable") for k in COUNTERS})
        line = progress_record(row)
        size = len(line.encode("ascii")) * (3 if observe is not None else 1)
        if sample_bytes + size > SAMPLE_BYTES:
            raise ValueError("resource sample byte cap")
        sample_bytes += size
        samples.append(row)
        if observe is not None:
            observe(row)
        next_sample = time.monotonic() + SAMPLE_INTERVAL
        if any(row[k] == "unavailable" for k in COUNTERS):
            raise ValueError("resource counter unavailable")
        if (row["memory_current"] >= guard["memory_bytes"] or
                row["memory_peak"] >= guard["memory_bytes"] or row["oom"] or row["oom_kill"]):
            raise ValueError("cgroup memory budget/oom event")
        if row["cpu_usage_usec"] >= guard["cpu_usec"]:
            raise ValueError("cgroup aggregate CPU budget")

    def capture_final():
        nonlocal sample_bytes
        samples = result["guard"]["samples"]
        if len(samples) >= SAMPLE_COUNT:
            result["errors"].append("wrapper failure: ValueError: resource sample count cap")
            return
        values = resource.sample()
        row = dict(type="resource_sample", index=index, sample=len(samples),
                   **{k: values.get(k, "unavailable") for k in COUNTERS})
        line = progress_record(row)
        size = len(line.encode("ascii")) * (3 if observe is not None else 1)
        if sample_bytes + size > SAMPLE_BYTES:
            result["errors"].append("wrapper failure: ValueError: resource sample byte cap")
            return
        sample_bytes += size
        samples.append(row)
        if observe is not None:
            try:
                observe(row)
            except Exception as exc:
                result["errors"].append(f"wrapper failure: {type(exc).__name__}: {exc}")
        if any(row[k] == "unavailable" for k in COUNTERS):
            result["errors"].append("wrapper failure: ValueError: resource counter unavailable")
        elif (row["memory_current"] >= guard["memory_bytes"] or
                row["memory_peak"] >= guard["memory_bytes"] or row["oom"] or row["oom_kill"]):
            result["errors"].append("wrapper failure: ValueError: cgroup memory budget/oom event")
        elif row["cpu_usage_usec"] >= guard["cpu_usec"]:
            result["errors"].append("wrapper failure: ValueError: cgroup aggregate CPU budget")

    def kill():
        try:
            if resource is not None:
                resource.kill()
        finally:
            if proc is not None and proc.returncode is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    try:
        if resource is not None:
            if handler_error:
                raise RuntimeError("guarded measurement requires termination handlers in the main thread")
            resource.setup()
            enforce_sample()
            if terminated:
                raise RuntimeError(f"terminated by signal {terminated[0]}; bounded cleanup")
        proc = subprocess.Popen(result["command"], cwd=cwd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True,
                                preexec_fn=resource.place if resource is not None else None)
        with selectors.DefaultSelector() as selector:
            for name in buffers:
                stream = getattr(proc, name)
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, name)
            reaped = False
            killed = False
            while selector.get_map() or not reaped:
                if terminated and not killed:
                    result["errors"].append(f"terminated by signal {terminated[0]}; bounded cleanup")
                    kill()
                    killed = True
                if resource is not None and not killed and time.monotonic() >= next_sample:
                    enforce_sample()
                if not killed and time.monotonic() - started > timeout:
                    result["errors"].append("timeout")
                    kill()
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
                            kill()
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
        if resource is not None:
            try:
                kill()
            except Exception as exc:
                result["errors"].append(f"cgroup kill failure: {exc}")
        if proc is not None:
            if proc.returncode is None:
                try:
                    kill()
                except Exception as exc:
                    result["errors"].append(f"child kill failure: {exc}")
                _, status, usage = os.wait4(proc.pid, 0)
                proc.returncode = os.waitstatus_to_exitcode(status)
                result["status"] = proc.returncode
                result["peak_rss_kib"] = (usage.ru_maxrss / 1024 if
                                           sys.platform == "darwin" else usage.ru_maxrss)
            for stream in (proc.stdout, proc.stderr):
                stream.close()
        if resource is not None:
            result["guard"]["path"] = str(resource.path) if resource.path is not None else None
            try:
                result["guard"]["cleanup"] = resource.cleanup(capture_final)
            except Exception as exc:
                result["guard"]["cleanup"] = dict(quiescent=False, removed=False)
                result["errors"].append(f"cgroup cleanup failure (reserved): {exc}")
            if installed:
                try:
                    signal.signal(signal.SIGTERM, old_term)
                    signal.signal(signal.SIGINT, old_int)
                except ValueError:
                    pass
            # Snapshot termination after cleanup, where a signal can still
            # arrive while quiescence is being established.
            if terminated and not any("terminated by signal" in e for e in result["errors"]):
                result["errors"].append(f"terminated by signal {terminated[0]}; bounded cleanup")
            result["terminated_by_signal"] = terminated[0] if terminated else None
        for name, data in buffers.items():
            try:
                result[name] = data.decode("utf-8")
            except UnicodeDecodeError:
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


class EvidenceFailure(Exception):
    pass


def run(files, shellcheck="shellcheck", *, rcfile=None, cap=OUTPUT_CAP, timeout=TIMEOUT,
        record=None, guard=None):
    """Return the full report; optionally emit incremental evidence records.

    rcfile is a fixture-only hook; neither command-line runner exposes it.
    Sink failures never become a successful summary; resource observer failures
    retain the child outcome when the evidence sink remains usable.
    """
    def emit(kind, data):
        if record is not None:
            try:
                record(dict(type=kind, **data))
            except Exception as exc:
                raise EvidenceFailure("evidence sink failure") from exc

    started = time.monotonic()
    report = dict(schema=1, cwd=str(ROOT), arguments=list(map(str, files)), manifest=[],
                  limits=dict(stream_bytes=cap, child_timeout_s=timeout),
                  version=None, targets=[], errors=[], target_diagnostics=[])
    path_errors = {}
    for index, path in enumerate(files):
        try:
            report["manifest"].append(canonical(path))
        except (OSError, RuntimeError, ValueError) as exc:
            # Preserve the occurrence even when path canonicalization fails;
            # unrepresentable live paths fail closed before their child starts.
            report["manifest"].append(os.path.abspath(ROOT / path))
            path_errors[index] = f"path resolution failure: {exc}"
    emit("header", {key: report[key] for key in ("schema", "cwd", "arguments", "manifest", "limits")})
    try:
        if not files:
            raise ValueError("empty manifest")
        version = measure([shellcheck, "--version"], cap=cap, timeout=timeout, guard=guard)
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
        if guard is not None and report["version"] is not None and (
                not report["version"]["guard"]["cleanup"]["quiescent"]
                or report["version"].get("terminated_by_signal") is not None):
            break  # Reserved leaf or catchable termination stops further targets.
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
            if record is not None:
                start = dict(index=index, target=relative_target(target), group_count=len(entry["group"]))
                progress_record(dict(type="target_start", **start))
                emit("target_start", start)  # Flush evidence and live sink before Popen.
            measured = measure(command, cap=cap, timeout=timeout, guard=guard,
                               observe=record, index=index)
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
        except EvidenceFailure:
            raise
        except Exception as exc:
            entry["errors"].append(f"target wrapper failure: {type(exc).__name__}: {exc}")
        report["target_diagnostics"].extend(entry["target_diagnostics"])
        entry["status"] = 2 if entry["errors"] else int(bool(entry["target_diagnostics"]))
        emit("target", entry)
        if guard is not None and entry["measurement"] is not None and not entry["measurement"]["guard"]["cleanup"]["quiescent"]:
            break  # No more work while a possibly populated cgroup remains reserved.
        if guard is not None and entry["measurement"] is not None and entry["measurement"].get("terminated_by_signal") is not None:
            break  # Catchable termination stops further targets after bounded cleanup.
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
    parser.add_argument("--progress", action="store_true",
                        help="flush bounded sanitized JSON progress to stdout (full evidence stays in --report)")
    parser.add_argument("--shellcheck", default="shellcheck", help="pinned CLI path (version checked)")
    if manifest is None:
        parser.add_argument("files", nargs="+")
    parser.add_argument("--timeout", type=float, default=TIMEOUT, help="seconds per child (default: 300)")
    parser.add_argument("--output-cap", type=int, default=OUTPUT_CAP,
                        help="bytes per child stream (default: 8388608)")
    parser.add_argument("--cgroup-parent", type=Path, help="opt-in delegated cgroup-v2 parent; no fallback")
    parser.add_argument("--memory-bytes", type=int, help="explicit hard child-cgroup memory.max")
    parser.add_argument("--cpu-usec", type=int, help="explicit aggregate child-cgroup CPU usage budget")
    parser.add_argument("--cpu-quota-usec", type=int, help="explicit finite child-cgroup cpu.max quota per period")
    parser.add_argument("--cpu-period-usec", type=int, help="explicit finite child-cgroup cpu.max period")
    args = parser.parse_args()
    guard = None
    if any(v is not None for v in (args.cgroup_parent, args.memory_bytes, args.cpu_usec,
                                   args.cpu_quota_usec, args.cpu_period_usec)):
        if (args.cgroup_parent is None or args.memory_bytes is None or args.cpu_usec is None or
                args.cpu_quota_usec is None or args.cpu_period_usec is None or
                not 0 < args.memory_bytes < 2**63 or not 0 < args.cpu_usec < 2**63 or
                not 0 < args.cpu_quota_usec < 2**63 or not 0 < args.cpu_period_usec < 2**63):
            parser.error("guard requires explicit parent and finite positive memory-bytes, cpu-usec, cpu-quota-usec and cpu-period-usec")
        guard = dict(parent=str(args.cgroup_parent), memory_bytes=args.memory_bytes, cpu_usec=args.cpu_usec,
                     cpu_quota_usec=args.cpu_quota_usec, cpu_period_usec=args.cpu_period_usec)
    if not 0 < args.timeout < float("inf") or args.output_cap < 1:
        parser.error("timeout must be finite and positive; output cap must be positive")
    try:
        # Exclusive creation prevents overwriting a source/rc or stale evidence.
        with args.report.open("x") as stream:
            def record(data):
                stream.write(json.dumps(data, ensure_ascii=True, allow_nan=False) + "\n")
                stream.flush()
                if args.progress:
                    sys.stdout.write(progress_record(data))
                    sys.stdout.flush()
            report = run(manifest if manifest is not None else args.files, args.shellcheck,
                         cap=args.output_cap, timeout=args.timeout, record=record, guard=guard)
    except (OSError, ValueError, EvidenceFailure) as exc:
        if args.progress:
            # Report/sink exceptions can contain absolute paths or raw data.
            print('{"type":"failure","schema":1,"status":2}', file=sys.stderr, flush=True)
        else:
            print(f"evidence report failure: {exc}", file=sys.stderr)
        return 2
    return report["status"]


if __name__ == "__main__":
    sys.exit(main())
