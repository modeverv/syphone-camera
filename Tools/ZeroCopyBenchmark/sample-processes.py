#!/usr/bin/env python3
"""Read-only macOS cumulative CPU/RSS sampler. No camera or process control."""
from __future__ import annotations

import argparse
import csv
import ctypes
from datetime import datetime, timezone
import errno
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


class RUsageV0(ctypes.Structure):
    # Darwin SDK sys/resource.h, RUSAGE_INFO_V0. CPU values are Mach ticks on
    # this platform; convert with mach_timebase_info, not a hard-coded 1e9.
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins",
            "wired", "resident", "footprint", "start", "exit",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def parse_ps_time(value):
    days = 0
    if "-" in value:
        prefix, value = value.split("-", 1)
        days = int(prefix)
    parts = value.split(":")
    seconds = float(parts[-1])
    if len(parts) >= 2:
        seconds += int(parts[-2]) * 60
    if len(parts) == 3:
        seconds += int(parts[-3]) * 3600
    if len(parts) > 3 or not math.isfinite(seconds) or seconds < 0:
        raise ValueError("invalid ps CPU time")
    return round((seconds + days * 86400) * 1_000_000_000)


class Sampler:
    def __init__(self, targets):
        self.targets = targets
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        self.system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        self.timebase = Timebase()
        if self.system.mach_timebase_info(ctypes.byref(self.timebase)) or not self.timebase.denom:
            raise RuntimeError("mach_timebase_info failed")
        self.backends = {}
        for label, pid in targets.items():
            raw = self.rusage(pid)
            self.backends[label] = "proc_pid_rusage" if "error" not in raw else "ps_cumulative_time"

    def rusage(self, pid):
        usage = RUsageV0()
        ctypes.set_errno(0)
        begin = time.monotonic_ns()
        result = self.lib.proc_pid_rusage(pid, 0, ctypes.byref(usage))
        end = time.monotonic_ns()
        if result:
            code = ctypes.get_errno()
            return {"error": os.strerror(code), "errno": code, "readMonotonicNS": (begin + end) // 2}
        ticks = int(usage.user + usage.system)
        return {
            "readMonotonicNS": (begin + end) // 2,
            "identity": str(usage.start),
            "userMachTicks": usage.user, "systemMachTicks": usage.system,
            "cpuNanoseconds": ticks * self.timebase.numer // self.timebase.denom,
            "residentBytes": usage.resident, "physicalFootprintBytes": usage.footprint,
            "idleWakeups": usage.idle_wakeups, "interruptWakeups": usage.interrupt_wakeups,
            "cpuResolutionNanoseconds": self.timebase.numer / self.timebase.denom,
        }

    def snapshot(self):
        begin = time.monotonic_ns()
        values = {}
        fallback = {label: pid for label, pid in self.targets.items()
                    if self.backends[label] == "ps_cumulative_time"}
        for label, pid in self.targets.items():
            if label not in fallback:
                values[label] = self.rusage(pid)
        if fallback:
            ps_begin = time.monotonic_ns()
            proc = subprocess.run(
                ["/bin/ps", "-p", ",".join(map(str, fallback.values())),
                 "-o", "pid=,time=,rss=,lstart="],
                text=True, capture_output=True, env={**os.environ, "LC_ALL": "C"}, check=False,
            )
            ps_end = time.monotonic_ns()
            rows = {}
            for line in proc.stdout.splitlines():
                match = re.fullmatch(r"\s*(\d+)\s+(\S+)\s+(\d+)\s+(.+?)\s*", line)
                if match:
                    pid, cpu, rss, started = match.groups()
                    rows[int(pid)] = {
                        "readMonotonicNS": (ps_begin + ps_end) // 2,
                        "identity": started, "cpuNanoseconds": parse_ps_time(cpu),
                        "residentBytes": int(rss) * 1024,
                        "physicalFootprintBytes": None,
                        "cpuResolutionNanoseconds": 10_000_000,
                        "fallbackReason": "proc_pid_rusage not permitted or unavailable",
                    }
            for label, pid in fallback.items():
                values[label] = rows.get(pid, {"error": "PID missing from ps",
                    "readMonotonicNS": (ps_begin + ps_end) // 2})
        for label, value in values.items():
            value.update(pid=self.targets[label], backend=self.backends[label])
        return {"monotonicNS": begin, "recordedAt": utc_now(), "processes": values,
                "readDurationNanoseconds": time.monotonic_ns() - begin}


def interval_metrics(previous, current):
    if "error" in previous or "error" in current:
        return {"valid": False, "reason": "missing process measurement"}
    if previous["identity"] != current["identity"]:
        return {"valid": False, "reason": "PID identity changed"}
    delta = current["cpuNanoseconds"] - previous["cpuNanoseconds"]
    elapsed = current["readMonotonicNS"] - previous["readMonotonicNS"]
    if elapsed <= 0 or delta < 0:
        return {"valid": False, "reason": "nonmonotonic counters"}
    return {"valid": True, "wallSeconds": elapsed / 1e9,
            "cpuSeconds": delta / 1e9, "cpuPercentOneCore": 100 * delta / elapsed}


def self_test():
    assert parse_ps_time("0:34.90") == 34_900_000_000
    assert parse_ps_time("1:02:03.25") == 3_723_250_000_000
    assert parse_ps_time("2-01:02:03.25") == 176_523_250_000_000
    sampler = Sampler({"self": os.getpid()})
    first = sampler.rusage(os.getpid())
    ru_first = resource.getrusage(resource.RUSAGE_SELF)
    deadline = time.monotonic() + .2
    while time.monotonic() < deadline:
        sum(range(400))
    last = sampler.rusage(os.getpid())
    ru_last = resource.getrusage(resource.RUSAGE_SELF)
    measured = (last["cpuNanoseconds"] - first["cpuNanoseconds"]) / 1e9
    reference = ru_last.ru_utime + ru_last.ru_stime - ru_first.ru_utime - ru_first.ru_stime
    assert .9 < measured / reference < 1.1, (measured, reference, "CPU unit mismatch")
    assert not interval_metrics(first, {**last, "identity": "changed"})["valid"]
    assert not interval_metrics(first, {**last, "cpuNanoseconds": 0})["valid"]
    print(json.dumps({"status": "passed", "cpuMeasuredSeconds": measured,
        "getrusageReferenceSeconds": reference,
        "machTimebase": {"numer": sampler.timebase.numer, "denom": sampler.timebase.denom}}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--pid", action="append", default=[], metavar="LABEL=PID")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("macOS is required")
    if args.self_test:
        self_test()
        return 0
    if not args.output or not args.pid:
        parser.error("--output and at least one --pid LABEL=PID are required")
    if not math.isfinite(args.duration) or not .1 <= args.duration <= 3600:
        parser.error("duration must be 0.1..3600 seconds")
    if not math.isfinite(args.interval) or not .1 <= args.interval <= args.duration:
        parser.error("interval must be 0.1..duration seconds")
    targets = {}
    for item in args.pid:
        try:
            label, pid = item.split("=", 1)
            pid = int(pid)
        except ValueError:
            parser.error("invalid --pid; expected LABEL=PID")
        if not re.fullmatch(r"[A-Za-z0-9_-]+", label) or label in targets or pid <= 0:
            parser.error("invalid/duplicate label or nonpositive PID")
        if pid in targets.values():
            parser.error("duplicate PID would double count CPU")
        targets[label] = pid
    sampler = Sampler(targets)
    for label, backend in sampler.backends.items():
        print(f"{label} pid={targets[label]} backend={backend}", flush=True)
    own_begin = resource.getrusage(resource.RUSAGE_SELF)
    child_begin = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = utc_now()
    first = sampler.snapshot()
    snapshots = [first]
    start_ns = first["monotonicNS"]
    deadline_ns = start_ns + round(args.duration * 1e9)
    next_ns = start_ns
    while next_ns < deadline_ns:
        next_ns = min(next_ns + round(args.interval * 1e9), deadline_ns)
        wait = (next_ns - time.monotonic_ns()) / 1e9
        if wait > 0:
            time.sleep(wait)
        current = sampler.snapshot()
        current["intervals"] = {label: interval_metrics(snapshots[-1]["processes"][label],
            current["processes"][label]) for label in targets}
        snapshots.append(current)
    own_end = resource.getrusage(resource.RUSAGE_SELF)
    child_end = resource.getrusage(resource.RUSAGE_CHILDREN)
    summaries = {}
    for label, pid in targets.items():
        valid = [s["processes"][label] for s in snapshots if "error" not in s["processes"][label]]
        whole = interval_metrics(snapshots[0]["processes"][label], snapshots[-1]["processes"][label])
        whole["valid"] &= all(s["intervals"][label]["valid"] for s in snapshots[1:])
        rss = [s["residentBytes"] for s in valid]
        summaries[label] = {"pid": pid, "backend": sampler.backends[label], **whole,
            "samples": len(snapshots), "validSamples": len(valid),
            "residentBytesMedian": statistics.median(rss) if rss else None,
            "residentBytesMax": max(rss) if rss else None,
            "residentBytesLast": rss[-1] if rss else None,
            "gpuTime": None, "gpuTimeAvailability": "not exposed by this sampler"}
    wall = (snapshots[-1]["monotonicNS"] - start_ns) / 1e9
    own_seconds = own_end.ru_utime + own_end.ru_stime - own_begin.ru_utime - own_begin.ru_stime
    child_seconds = child_end.ru_utime + child_end.ru_stime - child_begin.ru_utime - child_begin.ru_stime
    complete = all(s["valid"] for s in summaries.values())
    result = {"schemaVersion": 1, "status": "complete" if complete else "incomplete",
        "startedAt": started, "finishedAt": utc_now(), "requestedDurationSeconds": args.duration,
        "actualWallSeconds": wall, "intervalSeconds": args.interval,
        "cpuPercentConvention": "100 percent means one fully busy CPU core",
        "machTimebase": {"numer": sampler.timebase.numer, "denom": sampler.timebase.denom},
        "summaries": summaries,
        "summedTargetCPUPercentOneCore": sum(s["cpuPercentOneCore"] for s in summaries.values()) if complete else None,
        "measurementOverhead": {"samplerCPUSeconds": own_seconds, "psChildrenCPUSeconds": child_seconds,
            "cpuPercentOneCore": 100 * (own_seconds + child_seconds) / wall,
            "meanReadMilliseconds": statistics.mean(s["readDurationNanoseconds"] for s in snapshots) / 1e6},
        "snapshots": snapshots}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    if args.csv:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        fields = ["recordedAt", "elapsedSeconds", "label", "pid", "backend", "cpuNanoseconds",
                  "cpuPercentOneCore", "residentBytes", "physicalFootprintBytes", "error"]
        with args.csv.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields)
            writer.writeheader()
            for s in snapshots:
                for label, row in s["processes"].items():
                    writer.writerow({**{k: row.get(k) for k in fields if k in row},
                        "recordedAt": s["recordedAt"], "elapsedSeconds": (s["monotonicNS"] - start_ns) / 1e9,
                        "label": label, "cpuPercentOneCore": s.get("intervals", {}).get(label, {}).get("cpuPercentOneCore")})
    print(json.dumps({"status": result["status"], "summaries": summaries,
                      "measurementOverhead": result["measurementOverhead"]}), flush=True)
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
