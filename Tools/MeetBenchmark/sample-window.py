#!/usr/bin/env python3
"""Read-only, bounded CPU/producer window for an already-running Meet comparison.

This tool never starts/stops a process, camera, browser, or meeting. Browser CPU
is not proof of network sending; correlate cpu.json with a WebRTC-internals dump.
"""
from __future__ import annotations

import argparse
import csv
import ctypes
from datetime import datetime, timezone
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import resource
import statistics
import subprocess
import sys
import time


SAMPLER_PATH = Path(__file__).resolve().parents[1] / "ZeroCopyBenchmark/sample-processes.py"
spec = importlib.util.spec_from_file_location("zero_copy_process_sampler", SAMPLER_PATH)
process_sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(process_sampler)

DEFAULT_STATUS_DIR = Path.home() / (
    "Library/Containers/com.dream-jack.syphoncamera.probe/Data/Library/"
    "Application Support/SyphonZeroCopyCamera"
)
RESOLUTIONS = {"1080p": (1920, 1080), "720p": (1280, 720)}
COUNTERS = (
    "submitted", "renderedFrames", "transportPixelCopies", "cpuPixelCopies",
    "sourceTransformPasses", "gpuTimedFrames", "gpuTimingUnavailableFrames",
    "gpuCommandSecondsTotal", "renderWallSecondsTotal", "queuePressureDrops",
    "poolPressureDrops", "noNewFrameTicks", "unavailableFrameTicks",
)
CHROME_SCOPE = (
    "All Google Chrome processes present at the initial census, including shared "
    "GPU/network services, unrelated tabs, extensions, and any receiver tab. "
    "This is not Meet-only or sender-only CPU."
)

SYSTEM_CPU_SCOPE = "Whole Mac CPU tick utilization, including unrelated apps, receiver work, system services and this sampler; not Meet-only attribution"


class SystemCPUSampler:
    """SDK mach/host_info.h + mach/machine.h: HOST_CPU_LOAD_INFO=3, four natural_t ticks."""
    def __init__(self):
        self.error = None
        try:
            self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            self.lib.mach_host_self.argtypes = []
            self.lib.mach_host_self.restype = ctypes.c_uint32
            self.lib.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_uint32)]
            self.lib.host_statistics.restype = ctypes.c_int
            self.lib.mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
            self.lib.mach_port_deallocate.restype = ctypes.c_int
            self.lib.sysctlbyname.argtypes = [ctypes.c_char_p, ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
            self.lib.sysctlbyname.restype = ctypes.c_int
            # mach_init.h defines mach_task_self() as this borrowed global port.
            self.task_port = ctypes.c_uint32.in_dll(self.lib, "mach_task_self_").value
        except (OSError, AttributeError, ValueError) as error:
            self.error = str(error)

    def snapshot(self):
        begin = time.monotonic_ns()
        result = {"recordedAt": utc_now(), "backend": "host_statistics(HOST_CPU_LOAD_INFO)", "available": False}
        if self.error:
            return {**result, "error": self.error, "readMonotonicNS": begin, "readDurationNanoseconds": 0}
        cpu_count, cpu_size = ctypes.c_int(), ctypes.c_size_t(ctypes.sizeof(ctypes.c_int))
        cpu_status = self.lib.sysctlbyname(b"hw.logicalcpu", ctypes.byref(cpu_count), ctypes.byref(cpu_size), None, 0)
        result["cpuCount"] = cpu_count.value if cpu_status == 0 and cpu_count.value > 0 else None
        result["cpuCountSource"] = "sysctlbyname(hw.logicalcpu)"
        result["cpuCountReadReturnCode"] = cpu_status
        ticks = (ctypes.c_uint32 * 4)()
        count = ctypes.c_uint32(4)
        host_port = self.lib.mach_host_self()
        if host_port:
            try:
                status = self.lib.host_statistics(host_port, 3,
                    ctypes.cast(ticks, ctypes.POINTER(ctypes.c_int)), ctypes.byref(count))
            finally:
                # Each mach_host_self() call returns a send right owned here.
                result["portDeallocationReturnCode"] = self.lib.mach_port_deallocate(self.task_port, host_port)
            result.update(returnCode=status, count=count.value)
            if status == 0 and count.value == 4:
                result.update(available=True, ticks=dict(zip(("user", "system", "idle", "nice"), map(int, ticks))))
            else:
                result["error"] = f"host_statistics returned {status}, count={count.value}"
        else:
            result["error"] = "mach_host_self returned MACH_PORT_NULL"
        end = time.monotonic_ns()
        result.update(readMonotonicNS=(begin + end) // 2, readDurationNanoseconds=end - begin)
        return result


def system_cpu_metrics(previous, current):
    if not previous.get("available") or not current.get("available"):
        return {"valid": False, "reason": "system CPU statistics unavailable"}
    elapsed = current["readMonotonicNS"] - previous["readMonotonicNS"]
    deltas = {key: (current["ticks"][key] - previous["ticks"][key]) & 0xffffffff
              for key in ("user", "system", "idle", "nice")}
    total = sum(deltas.values())
    if total == 0 or elapsed <= 0:
        return {"valid": False, "reason": "system CPU ticks/time did not advance", "tickDeltas": deltas}
    busy = 100 * (total - deltas["idle"]) / total
    count = previous.get("cpuCount")
    stable_count = isinstance(count, int) and count > 0 and count == current.get("cpuCount")
    return {"valid": True, "tickDeltas": deltas, "totalTickDelta": total,
            "wallSeconds": elapsed / 1e9, "systemBusyPercentAllCores": busy,
            "systemBusyPercentOneCoreEquivalent": busy * count if stable_count else None,
            "cpuCount": count if stable_count else None, "cpuCountStable": stable_count,
            "cpuCountBefore": previous.get("cpuCount"), "cpuCountAfter": current.get("cpuCount"),
            "counterArithmetic": "unsigned 32-bit modular deltas"}


def take_snapshot(sampler, system_sampler):
    result = sampler.snapshot()
    system = system_sampler.snapshot()
    result["systemCPU"] = system
    result["readDurationNanoseconds"] += system["readDurationNanoseconds"]
    return result


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def process_census():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="],
        text=True, capture_output=True, check=True, env={**os.environ, "LC_ALL": "C"},
    )
    rows = []
    pattern = re.compile(r"\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.+?)\s*$")
    for line in result.stdout.splitlines():
        match = pattern.fullmatch(line)
        if match:
            pid, ppid, started, executable = match.groups()
            rows.append({"pid": int(pid), "parentPID": int(ppid),
                         "startTime": started, "executable": executable})
    if not rows:
        raise RuntimeError("Process census returned no parseable rows")
    return rows


def categories(row):
    executable = row["executable"]
    name = Path(executable).name
    result = []
    if name == "SyphonZeroCopyCamera":
        result.append("host")
    if name == "com.dream-jack.syphoncamera.probe.camera":
        result.append("extension")
    if name == "Webcam Motion Receiver":
        result.append("wmc")
    if name == "cameracaptured":
        result.append("cameracaptured")
    if name == "Google Chrome" or name.startswith("Google Chrome Helper") or "/Google Chrome.app/" in executable:
        result.append("allChrome")
    return result


def select_targets(census, explicit, all_chrome):
    by_pid = {row["pid"]: row for row in census}
    missing = set(explicit.values()) - set(by_pid)
    if missing:
        raise RuntimeError(f"Explicit PIDs are missing: {sorted(missing)}")
    targets = dict(explicit)
    labels = {pid: label for label, pid in targets.items()}
    groups = {name: [] for name in ("host", "extension", "wmc", "cameracaptured", "allChrome")}
    for row in sorted(census, key=lambda item: item["pid"]):
        roles = [role for role in categories(row) if role != "allChrome" or all_chrome]
        if not roles:
            continue
        pid = row["pid"]
        if pid not in labels:
            base = roles[0]
            label = base if base not in targets else f"{base}_{pid}"
            while label in targets:
                label += "_auto"
            targets[label] = pid
            labels[pid] = label
        for role in roles:
            groups[role].append(labels[pid])
    return targets, groups


def relevant_census(census, targets, all_chrome):
    pids = set(targets.values())
    return {"recordedAt": utc_now(), "monotonicNS": time.monotonic_ns(),
            "processes": [row for row in census if row["pid"] in pids or
                          any(role != "allChrome" or all_chrome for role in categories(row))]}


def compare_census(before, after, targets, all_chrome):
    def identity(row):
        return row["pid"], row["startTime"], row["executable"]
    old = {identity(row) for row in before["processes"]}
    new = {identity(row) for row in after["processes"]}
    changes = {"stable": old == new, "added": [list(item) for item in sorted(new - old)],
               "removed": [list(item) for item in sorted(old - new)]}
    old_pids = {row["pid"]: identity(row) for row in before["processes"]}
    new_pids = {row["pid"]: identity(row) for row in after["processes"]}
    changes["sampledPIDIdentitiesStable"] = all(old_pids.get(pid) == new_pids.get(pid) for pid in targets.values())
    if all_chrome:
        chrome_old = {identity(row) for row in before["processes"] if "allChrome" in categories(row)}
        chrome_new = {identity(row) for row in after["processes"] if "allChrome" in categories(row)}
        changes["allChromeRosterStable"] = chrome_old == chrome_new
    return changes


def read_status(directory):
    result = {"readAt": utc_now(), "readMonotonicNS": time.monotonic_ns(), "files": {}}
    for label, filename in (("producer", "producer-status.json"), ("extension", "extension-telemetry.json")):
        path = directory / filename
        with path.open("rb") as stream:
            raw = stream.read()
            modified = os.fstat(stream.fileno()).st_mtime
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise RuntimeError(f"{filename} is not a JSON object")
        result[label] = value
        result["files"][label] = {"path": str(path), "modifiedAt": datetime.fromtimestamp(modified, timezone.utc).isoformat(),
                                  "ageSecondsAtRead": time.time() - modified}
    return result


def observed_source_kind(producer):
    if producer.get("sourceKind"):
        return producer["sourceKind"]
    if producer.get("transportMode") in ("zero-copy", "gpu-copy"):
        return "native-pattern"
    return "unknown"


def validate_status(reading, dimensions, source_kind, max_age):
    producer, extension = reading["producer"], reading["extension"]
    failures = []
    if producer.get("running") is not True:
        failures.append("producer is not running")
    if (producer.get("outputWidth"), producer.get("outputHeight")) != dimensions:
        failures.append("producer output dimensions do not match requested resolution")
    if observed_source_kind(producer) != source_kind:
        failures.append("producer source kind does not match --source-kind")
    for name in ("producer", "extension"):
        age = reading["files"][name]["ageSecondsAtRead"]
        if not -2 <= age <= max_age:
            failures.append(f"{name} status file is stale or future-dated ({age:.2f}s)")
    if extension.get("sinkActive") is not True:
        failures.append("extension sink is not active")
    if (extension.get("width"), extension.get("height")) != dimensions or extension.get("frameRate") != 30:
        failures.append("extension native format does not match requested resolution at 30fps")
    if not numeric(extension.get("sourceClients")) or extension["sourceClients"] < 1:
        failures.append("extension has no active camera consumer")
    if not numeric(producer.get("hostTimeSeconds")) or not numeric(producer.get("submitted")):
        failures.append("producer timing/frame counters are unavailable")
    return failures


def producer_delta(before, after):
    first_time, last_time = before.get("hostTimeSeconds"), after.get("hostTimeSeconds")
    seconds = last_time - first_time if numeric(first_time) and numeric(last_time) else None
    errors, deltas = [], {}
    if not numeric(seconds) or seconds <= 0:
        errors.append("producer status timestamps did not advance")
    for key in COUNTERS:
        first, last = before.get(key), after.get(key)
        if not numeric(first) or not numeric(last):
            deltas[key] = None
        else:
            deltas[key] = last - first
            if deltas[key] < 0:
                errors.append(f"producer counter reset: {key}")
    if deltas["submitted"] is None or deltas["submitted"] <= 0:
        errors.append("producer submitted no frames in this interval")
    valid = not errors
    rate = lambda key: deltas[key] / seconds if valid and deltas[key] is not None else None
    gpu_frames = deltas["gpuTimedFrames"]
    gpu_seconds = deltas["gpuCommandSecondsTotal"]
    return {"valid": valid, "errors": errors, "statusClockWindowSeconds": seconds,
            "counterDeltas": deltas, "submittedFramesPerSecond": rate("submitted"),
            "renderedFramesPerSecond": rate("renderedFrames"),
            "producerGPUCommandMillisecondsPerSecond": 1000 * rate("gpuCommandSecondsTotal") if rate("gpuCommandSecondsTotal") is not None else None,
            "producerGPUCommandMillisecondsPerTimedFrame": 1000 * gpu_seconds / gpu_frames if valid and gpu_frames and gpu_seconds is not None else None,
            "gpuTimeScope": "Completed producer command buffers only; not GPU utilization or Chrome GPU time",
            "sourceFPSScope": "Output-admitted producer frames; not upstream WMC capture/tracking/render FPS"}


def write_cpu_csv(path, snapshots, targets):
    fields = ["recordedAt", "elapsedSeconds", "label", "pid", "backend", "cpuNanoseconds",
              "cpuPercentOneCore", "residentBytes", "physicalFootprintBytes", "error"]
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        for snapshot in snapshots:
            for label in targets:
                row = snapshot["processes"][label]
                writer.writerow({**{key: row.get(key) for key in fields if key in row},
                    "recordedAt": snapshot["recordedAt"], "elapsedSeconds": (snapshot["monotonicNS"] - snapshots[0]["monotonicNS"]) / 1e9,
                    "label": label, "cpuPercentOneCore": snapshot.get("intervals", {}).get(label, {}).get("cpuPercentOneCore")})


def summarize_cpu(snapshots, sampler, groups, census_changes, requested_duration, interval, overhead):
    summaries = {}
    for label, pid in sampler.targets.items():
        rows = [sample["processes"][label] for sample in snapshots]
        whole = process_sampler.interval_metrics(rows[0], rows[-1])
        whole["valid"] &= all(sample["intervals"][label]["valid"] for sample in snapshots[1:])
        rss = [row["residentBytes"] for row in rows if "residentBytes" in row]
        summaries[label] = {"pid": pid, "backend": sampler.backends[label], **whole,
            "samples": len(rows), "residentBytesMedian": statistics.median(rss) if rss else None,
            "residentBytesMax": max(rss) if rss else None, "gpuTime": None,
            "gpuTimeAvailability": "not exposed by this process sampler"}
    aggregates = {}
    for group, labels in groups.items():
        if not labels:
            continue
        valid = all(summaries[label]["valid"] for label in labels)
        if group == "allChrome":
            valid &= census_changes.get("allChromeRosterStable", False)
        aggregates[group] = {"labels": labels, "pids": [sampler.targets[label] for label in labels], "valid": valid,
            "cpuPercentOneCore": sum(summaries[label]["cpuPercentOneCore"] for label in labels) if valid else None,
            "scope": CHROME_SCOPE if group == "allChrome" else f"Processes identified as {group}"}
    complete = len(snapshots) > 1 and all(item["valid"] for item in summaries.values()) and census_changes["stable"]
    system_rows = [row.get("systemCPU", {"available": False}) for row in snapshots]
    system_summary = system_cpu_metrics(system_rows[0], system_rows[-1])
    system_summary["valid"] &= all(system_cpu_metrics(a, b)["valid"] for a, b in zip(system_rows, system_rows[1:]))
    if not all(row.get("cpuCount") == system_rows[0].get("cpuCount") for row in system_rows):
        system_summary.update(cpuCountStable=False, cpuCount=None, systemBusyPercentOneCoreEquivalent=None)
    system_summary.update(scope=SYSTEM_CPU_SCOPE, first=system_rows[0], last=system_rows[-1],
                          samples=len(system_rows), availableSamples=sum(bool(row.get("available")) for row in system_rows),
                          percentConvention="AllCores ranges 0..100; OneCoreEquivalent multiplies by the unchanged logical CPU count")
    return {"schemaVersion": 1, "status": "complete" if complete else "incomplete",
        "startedAt": snapshots[0]["recordedAt"], "finishedAt": snapshots[-1]["recordedAt"],
        "startMonotonicNS": snapshots[0]["monotonicNS"], "endMonotonicNS": snapshots[-1]["monotonicNS"],
        "requestedDurationSeconds": requested_duration,
        "actualWallSeconds": (snapshots[-1]["monotonicNS"] - snapshots[0]["monotonicNS"]) / 1e9,
        "intervalSeconds": interval, "cpuPercentConvention": "100 percent means one fully busy CPU core",
        "machTimebase": {"numer": sampler.timebase.numer, "denom": sampler.timebase.denom},
        "summaries": summaries, "aggregates": aggregates,
        "summedTargetCPUPercentOneCore": sum(item["cpuPercentOneCore"] for item in summaries.values()) if complete else None,
        "summedTargetScope": "Deduplicated explicitly selected and automatically discovered PIDs; not whole-system or Meet-only CPU",
        "censusChanges": census_changes, "measurementOverhead": overhead, "systemCPU": system_summary, "snapshots": snapshots}


def self_test():
    system_first = {"available": True, "cpuCount": 8, "readMonotonicNS": 1,
                    "ticks": {"user": 100, "system": 100, "idle": 100, "nice": 0}}
    system_last = {"available": True, "cpuCount": 8, "readMonotonicNS": 1_000_000_001,
                   "ticks": {"user": 110, "system": 110, "idle": 180, "nice": 0}}
    system_metric = system_cpu_metrics(system_first, system_last)
    assert system_metric["systemBusyPercentAllCores"] == 20
    assert system_metric["systemBusyPercentOneCoreEquivalent"] == 160
    assert system_cpu_metrics(system_first, {**system_last, "cpuCount": 4})["systemBusyPercentOneCoreEquivalent"] is None
    wrap_first = {**system_first, "ticks": {"user": 0xfffffffe, "system": 0, "idle": 0, "nice": 0}}
    wrap_last = {**system_last, "ticks": {"user": 3, "system": 0, "idle": 5, "nice": 0}}
    assert system_cpu_metrics(wrap_first, wrap_last)["systemBusyPercentAllCores"] == 50
    assert not system_cpu_metrics({"available": False}, system_last)["valid"]
    rows = [
        {"pid": 1, "parentPID": 0, "startTime": "a", "executable": "/A/SyphonZeroCopyCamera"},
        {"pid": 2, "parentPID": 0, "startTime": "a", "executable": "/A/com.dream-jack.syphoncamera.probe.camera"},
        {"pid": 3, "parentPID": 0, "startTime": "a", "executable": "/A/Google Chrome"},
        {"pid": 4, "parentPID": 3, "startTime": "a", "executable": "/A/Google Chrome Helper (Renderer)"},
    ]
    targets, groups = select_targets(rows, {"meet_a": 4}, True)
    assert list(targets.values()).count(4) == 1 and "meet_a" in groups["allChrome"]
    before = relevant_census(rows, targets, True)
    after = relevant_census(rows + [{"pid": 5, "parentPID": 3, "startTime": "b", "executable": "/A/Google Chrome Helper"}], targets, True)
    assert not compare_census(before, after, targets, True)["allChromeRosterStable"]
    class FakeSampler:
        pass
    fake = FakeSampler()
    fake.targets = targets
    fake.backends = {label: "fixture" for label in targets}
    fake.timebase = type("Timebase", (), {"numer": 1, "denom": 1})()
    snapshots = []
    for tick in range(2):
        processes = {label: {"pid": pid, "identity": "same", "readMonotonicNS": (tick + 1) * 1_000_000_000,
                            "cpuNanoseconds": tick * 1_000_000_000, "residentBytes": 1024}
                     for label, pid in targets.items()}
        snapshot = {"monotonicNS": (tick + 1) * 1_000_000_000, "recordedAt": f"2026-01-01T00:00:0{tick}Z", "processes": processes}
        if tick:
            snapshot["intervals"] = {label: process_sampler.interval_metrics(snapshots[0]["processes"][label], processes[label]) for label in targets}
        snapshots.append(snapshot)
    stable = compare_census(before, before, targets, True)
    cpu = summarize_cpu(snapshots, fake, groups, stable, 1, 1, {})
    assert cpu["aggregates"]["allChrome"]["cpuPercentOneCore"] == 200
    assert cpu["summedTargetCPUPercentOneCore"] == 400
    changed = summarize_cpu(snapshots, fake, groups, compare_census(before, after, targets, True), 1, 1, {})
    assert changed["status"] == "incomplete" and changed["aggregates"]["allChrome"]["cpuPercentOneCore"] is None
    first = {"hostTimeSeconds": 1, "submitted": 10, "renderedFrames": 10, "gpuTimedFrames": 10, "gpuCommandSecondsTotal": .01}
    last = {"hostTimeSeconds": 3, "submitted": 70, "renderedFrames": 70, "gpuTimedFrames": 70, "gpuCommandSecondsTotal": .07}
    assert producer_delta(first, last)["submittedFramesPerSecond"] == 30
    assert not producer_delta(first, {**last, "submitted": 10})["valid"]
    assert not producer_delta(first, {**last, "submitted": 1})["valid"]
    assert not producer_delta(first, {**last, "hostTimeSeconds": None})["valid"]
    reading = {"producer": {"running": True, "outputWidth": 1280, "outputHeight": 720, "sourceKind": "syphon", **first},
        "extension": {"sinkActive": True, "width": 1280, "height": 720, "frameRate": 30, "sourceClients": 1},
        "files": {name: {"ageSecondsAtRead": 1} for name in ("producer", "extension")}}
    assert not validate_status(reading, (1280, 720), "syphon", 4)
    assert validate_status(reading, (1920, 1080), "syphon", 4)
    reading["producer"]["running"] = False
    assert validate_status(reading, (1280, 720), "syphon", 4)
    reading["producer"]["running"] = True
    reading["files"]["extension"]["ageSecondsAtRead"] = 10
    assert validate_status(reading, (1280, 720), "syphon", 4)
    print("PASS: system CPU ticks/wrap/count-change, PID deduplication, Chrome census churn, source FPS/counter resets, resolution/running/stale preflight checks; no camera/process sampling")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolution", choices=RESOLUTIONS)
    parser.add_argument("--output-dir", type=Path, help="Must not exist; old results are never overwritten")
    parser.add_argument("--duration", type=float, default=40)
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--preflight-seconds", type=float, default=5)
    parser.add_argument("--max-status-age", type=float, default=4)
    parser.add_argument("--source-kind", choices=("syphon", "native-pattern"), default="syphon")
    parser.add_argument("--status-dir", type=Path, default=DEFAULT_STATUS_DIR)
    parser.add_argument("--pid", action="append", default=[], metavar="LABEL=PID")
    parser.add_argument("--all-chrome", action="store_true", help=CHROME_SCOPE)
    parser.add_argument("--meeting-send-resolution-setting", help="User-set intent only; never treated as actual outbound resolution")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if sys.platform != "darwin":
        parser.error("macOS is required")
    if not args.resolution or not args.output_dir:
        parser.error("--resolution and --output-dir are required")
    for name, low, high in (("duration", 1, 600), ("interval", .1, 60), ("preflight_seconds", 1, 30), ("max_status_age", 1, 30)):
        value = getattr(args, name)
        if not math.isfinite(value) or not low <= value <= high:
            parser.error(f"--{name.replace('_', '-')} must be {low}..{high}")
    if args.interval > args.duration:
        parser.error("--interval cannot exceed --duration")
    explicit = {}
    for item in args.pid:
        try:
            label, pid_text = item.split("=", 1)
            pid = int(pid_text)
        except ValueError:
            parser.error("--pid requires LABEL=PID")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", label) or label in explicit or pid <= 0 or pid in explicit.values():
            parser.error("Invalid/duplicate explicit label or PID")
        explicit[label] = pid
    output = args.output_dir.expanduser().resolve()
    args.status_dir = args.status_dir.expanduser().resolve()
    try:
        output.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        parser.error("--output-dir already exists; choose a new directory")
    width, height = RESOLUTIONS[args.resolution]
    manifest = {"schemaVersion": 1, "createdAt": utc_now(), "tool": str(Path(__file__).resolve()),
        "samplerModule": str(SAMPLER_PATH), "expectedCameraResolution": {"width": width, "height": height, "fps": 30},
        "sourceKindRequested": args.source_kind, "statusDirectory": str(args.status_dir),
        "requestedDurationSeconds": args.duration, "intervalSeconds": args.interval, "preflightSeconds": args.preflight_seconds,
        "explicitPIDs": explicit, "allChromeRequested": args.all_chrome, "allChromeScope": CHROME_SCOPE,
        "systemCPURequested": True, "systemCPUScope": SYSTEM_CPU_SCOPE,
        "meetingSendResolutionSetting": args.meeting_send_resolution_setting,
        "networkSendingVerified": False, "actualOutboundEvidence": "Requires a separate time-aligned WebRTC-internals dump"}
    save_json(output / "manifest.json", manifest)
    try:
        preflight_first = read_status(args.status_dir)
        save_json(output / "preflight-first.json", preflight_first)
        failures = validate_status(preflight_first, (width, height), args.source_kind, args.max_status_age)
        if failures:
            raise RuntimeError("Preflight: " + "; ".join(failures))
        print(f"Preflight {args.preflight_seconds:g}s: waiting for positive live frame counters", flush=True)
        time.sleep(args.preflight_seconds)
        preflight_last = read_status(args.status_dir)
        preflight = {"reading": preflight_last, "delta": producer_delta(preflight_first["producer"], preflight_last["producer"])}
        save_json(output / "preflight-last.json", preflight)
        failures = validate_status(preflight_last, (width, height), args.source_kind, args.max_status_age) + preflight["delta"]["errors"]
        if failures:
            raise RuntimeError("Preflight: " + "; ".join(failures))
        census = process_census()
        targets, groups = select_targets(census, explicit, args.all_chrome)
        if len(groups["host"]) != 1 or len(groups["extension"]) != 1:
            raise RuntimeError("Expected exactly one native host and camera extension process")
        if args.source_kind == "syphon" and not groups["wmc"]:
            raise RuntimeError("WMC process not found for --source-kind syphon")
        if args.all_chrome and not groups["allChrome"]:
            raise RuntimeError("--all-chrome requested but no Google Chrome process was found")
        census_before = relevant_census(census, targets, args.all_chrome)
        save_json(output / "census-before.json", census_before)
        sampler = process_sampler.Sampler(targets)
        system_sampler = SystemCPUSampler()
        manifest.update(targets=targets, groups=groups, backends=sampler.backends)
        save_json(output / "manifest.json", manifest)
        own_begin, children_begin = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
        initial_status = read_status(args.status_dir)
        save_json(output / "producer-before.json", initial_status["producer"])
        save_json(output / "extension-before.json", initial_status["extension"])
        snapshots = [take_snapshot(sampler, system_sampler)]
        telemetry = [initial_status]
        deadline = snapshots[0]["monotonicNS"] + round(args.duration * 1e9)
        next_ns = snapshots[0]["monotonicNS"]
        interruption = None
        print(f"Sampling {args.duration:g}s: {targets}", flush=True)
        with (output / "cpu-snapshots.jsonl").open("w") as cpu_stream, (output / "telemetry.jsonl").open("w") as status_stream:
            cpu_stream.write(json.dumps(snapshots[0]) + "\n"); cpu_stream.flush()
            status_stream.write(json.dumps(initial_status) + "\n"); status_stream.flush()
            try:
                while next_ns < deadline:
                    next_ns = min(next_ns + round(args.interval * 1e9), deadline)
                    time.sleep(max(0, (next_ns - time.monotonic_ns()) / 1e9))
                    current = take_snapshot(sampler, system_sampler)
                    current["intervals"] = {label: process_sampler.interval_metrics(snapshots[-1]["processes"][label], current["processes"][label]) for label in targets}
                    current["systemCPUInterval"] = system_cpu_metrics(snapshots[-1]["systemCPU"], current["systemCPU"])
                    snapshots.append(current)
                    cpu_stream.write(json.dumps(current) + "\n"); cpu_stream.flush()
                    reading = read_status(args.status_dir)
                    telemetry.append(reading)
                    status_stream.write(json.dumps(reading) + "\n"); status_stream.flush()
            except KeyboardInterrupt:
                interruption = "interrupted"
        own_end, children_end = resource.getrusage(resource.RUSAGE_SELF), resource.getrusage(resource.RUSAGE_CHILDREN)
        census_after = relevant_census(process_census(), targets, args.all_chrome)
        save_json(output / "census-after.json", census_after)
        census_changes = compare_census(census_before, census_after, targets, args.all_chrome)
        wall = (snapshots[-1]["monotonicNS"] - snapshots[0]["monotonicNS"]) / 1e9
        cpu_seconds = lambda first, last: last.ru_utime + last.ru_stime - first.ru_utime - first.ru_stime
        overhead = {"samplerCPUSeconds": cpu_seconds(own_begin, own_end), "psChildrenCPUSeconds": cpu_seconds(children_begin, children_end),
                    "meanReadMilliseconds": statistics.mean(row["readDurationNanoseconds"] for row in snapshots) / 1e6}
        overhead["cpuPercentOneCore"] = 100 * (overhead["samplerCPUSeconds"] + overhead["psChildrenCPUSeconds"]) / wall if wall else None
        cpu = summarize_cpu(snapshots, sampler, groups, census_changes, args.duration, args.interval, overhead)
        if interruption:
            cpu.update(status="incomplete", interruption=interruption)
        save_json(output / "cpu.json", cpu)
        write_cpu_csv(output / "cpu.csv", snapshots, targets)
        final_status = telemetry[-1]
        save_json(output / "producer-after.json", final_status["producer"])
        save_json(output / "extension-after.json", final_status["extension"])
        failures = [interruption] if interruption else []
        for index, reading in enumerate(telemetry):
            failures.extend(f"telemetry[{index}]: {reason}" for reason in validate_status(reading, (width, height), args.source_kind, args.max_status_age))
            if index and reading["producer"].get("hostTimeSeconds") != telemetry[index-1]["producer"].get("hostTimeSeconds"):
                failures.extend(f"telemetry[{index}]: {reason}" for reason in producer_delta(telemetry[index-1]["producer"], reading["producer"])["errors"])
            for key in ("transportMode", "sourceServer"):
                if reading["producer"].get(key) != initial_status["producer"].get(key):
                    failures.append(f"telemetry[{index}]: producer {key} changed during measurement")
            if reading["extension"].get("generation") != initial_status["extension"].get("generation"):
                failures.append(f"telemetry[{index}]: extension producer session changed during measurement")
        if cpu["status"] != "complete":
            failures.append("process measurements or PID census were incomplete/changed")
        delta = producer_delta(initial_status["producer"], final_status["producer"])
        failures.extend(delta["errors"])
        extension_deltas = {key: final_status["extension"].get(key, 0) - initial_status["extension"].get(key, 0)
                            for key in ("received", "forwarded", "rejected", "consumeErrors", "droppedNoConsumers")}
        if any(value < 0 for value in extension_deltas.values()) or extension_deltas["rejected"] or extension_deltas["consumeErrors"]:
            failures.append("extension counters reset or new rejection/consume errors occurred")
        if extension_deltas["forwarded"] <= 0:
            failures.append("extension forwarded no frames during the window")
        summary = {"schemaVersion": 1, "status": "complete" if not failures else "incomplete", "failures": failures,
            "startedAt": cpu["startedAt"], "finishedAt": cpu["finishedAt"], "actualWallSeconds": wall,
            "resolution": args.resolution, "sourceKind": args.source_kind, "producer": delta,
            "expectedFramesPerSecond": 30,
            "producerSubmittedFPSWithinOneOf30": delta["submittedFramesPerSecond"] is not None and abs(delta["submittedFramesPerSecond"] - 30) <= 1,
            "extensionCounterDeltas": extension_deltas, "processSummaries": cpu["summaries"],
            "processAggregates": cpu["aggregates"], "censusChanges": census_changes,
            "systemCPU": cpu["systemCPU"],
            "producerCounterWindowScope": "Host-written status timestamps bracket the counter window; updates can differ from CPU boundaries by one status interval",
            "networkSendingVerified": False, "nextEvidence": "Pass cpu.json to analyze-webrtc.py --process-samples with an exported WebRTC dump"}
        save_json(output / "summary.json", summary)
        manifest.update(startedAt=cpu["startedAt"], finishedAt=cpu["finishedAt"], startMonotonicNS=cpu["startMonotonicNS"], endMonotonicNS=cpu["endMonotonicNS"], status=summary["status"])
        save_json(output / "manifest.json", manifest)
        print(json.dumps({"status": summary["status"], "outputDirectory": str(output), "submittedFPS": delta["submittedFramesPerSecond"], "failures": failures}), flush=True)
        return 0 if not failures else 1
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        failure = {"status": "aborted", "recordedAt": utc_now(), "error": str(error) or "interrupted", "networkSendingVerified": False}
        save_json(output / "failure.json", failure)
        manifest.update(status="aborted", error=failure["error"])
        save_json(output / "manifest.json", manifest)
        print(json.dumps(failure), file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
