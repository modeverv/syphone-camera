#!/usr/bin/env python3
"""Offline analysis of the controlled native-camera copy/no-copy benchmark.

Reads immutable capture/sampler/producer artifacts; never opens a camera.
Usage: analyze.py COMPARISON_DIRECTORY [--allow-partial] [--output FILE]
                  [--markdown FILE]
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import statistics


PIPELINE = ("host", "extension", "consumer")
SIDECARS = ("camera_service", "background_wmc")
MODES = ("zero-copy", "gpu-copy")
REQUIRED = ("processes.json", "producer-before.json", "producer-after.json",
            "extension-before.json", "extension-after.json", "capture.json")
THERMAL_NAMES = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}


def load(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return value


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def stats(values):
    values = [v for v in values if number(v)]
    return {"n": len(values), "mean": statistics.mean(values) if values else None,
            "median": statistics.median(values) if values else None,
            "min": min(values) if values else None, "max": max(values) if values else None,
            "sampleSD": statistics.stdev(values) if len(values) > 1 else None}


def cmtime_seconds(value):
    if not isinstance(value, dict):
        return None
    numerator, scale = value.get("value"), value.get("timescale")
    if (not number(numerator) or not number(scale) or scale <= 0
            or value.get("epoch", 0) != 0 or not (int(value.get("flags", 0)) & 1)):
        return None
    return numerator / scale


def counter_delta(before, after, name):
    a, b = before.get(name), after.get(name)
    if not number(a) or not number(b) or b < a:
        return None
    return b - a


def analyze_run(entry, base):
    directory = Path(entry["directory"])
    if not directory.exists():
        directory = base / directory.name
    files = {name: directory / name for name in REQUIRED}
    missing = [name for name, path in files.items() if not path.exists()]
    if missing:
        return {"index": entry["index"], "mode": entry["mode"],
                "directory": str(directory), "status": "pending", "missingFiles": missing}
    documents = {name: load(path) for name, path in files.items()}
    sampled = documents["processes.json"]
    before, after = documents["producer-before.json"], documents["producer-after.json"]
    ext_before, ext_after = documents["extension-before.json"], documents["extension-after.json"]
    capture = documents["capture.json"]
    failures, warnings = [], []
    snapshots = sampled.get("snapshots", [])
    if len(snapshots) < 2:
        raise ValueError(f"Sampler requires two snapshots: {directory}")
    start = snapshots[0]["monotonicNS"] / 1e9
    end = snapshots[-1]["monotonicNS"] / 1e9
    elapsed = end - start
    if elapsed <= 0:
        raise ValueError(f"Nonpositive sampler window: {directory}")
    if sampled.get("status") != "complete":
        failures.append("process sampling incomplete")
    if capture.get("status") != "passed":
        failures.append("capture did not pass")
    if capture.get("pixelReadbackEnabled") is not False:
        failures.append("consumer pixel readback was enabled or unspecified")
    if capture.get("nativeOutputRequested") is not True or capture.get("requestedVideoSettings") != {}:
        failures.append("consumer did not request device-native samples")
    if capture.get("retentionHoldMilliseconds") != 0:
        failures.append("consumer retained frames for diagnostic checks")
    for label, report in (("before", before), ("after", after)):
        if report.get("transportMode") != entry["mode"] or report.get("benchmarkMode") is not True:
            failures.append(f"producer {label} mode does not match benchmark")
        if report.get("running") is not True:
            failures.append(f"producer was not running at {label} snapshot")

    producer_start, producer_end = before.get("hostTimeSeconds"), after.get("hostTimeSeconds")
    aligned = number(producer_start) and number(producer_end) and producer_end > producer_start
    start_lag = start - producer_start if aligned else None
    end_lag = end - producer_end if aligned else None
    # Producer publishes once a second; tolerate its stale snapshot, not an
    # arbitrary epoch offset. A small negative end lag can arise while writing
    # the sampler report immediately before taking the producer snapshot.
    aligned = bool(aligned and -.25 <= start_lag <= 2.0 and -.25 <= end_lag <= 2.0)
    if not aligned:
        failures.append("producer host clock and sampler monotonic window do not align within snapshot refresh lag")
    frame_times = []
    invalid_times = 0
    bad_format = 0
    for frame in capture.get("frames", []):
        received = cmtime_seconds(frame.get("receivedHostTime"))
        pts = cmtime_seconds(frame.get("pts"))
        if received is None or pts is None:
            invalid_times += 1
            continue
        if (frame.get("width"), frame.get("height"), frame.get("pixelFormat")) != (1920, 1080, "BGRA"):
            bad_format += 1
        frame_times.append((received, pts))
    if invalid_times or bad_format:
        failures.append(f"invalid frame time/format records: {invalid_times}/{bad_format}")
    coverage = bool(frame_times and frame_times[0][0] <= start and frame_times[-1][0] >= end)
    if not coverage:
        failures.append("capture does not cover the full sampler window")
    selected = [(received, pts) for received, pts in frame_times if start <= received <= end] if aligned else []
    if len(selected) < max(10, math.floor(elapsed * 20)):
        failures.append("too few receiver frames in the sampler clock window")
    latencies = [(received - pts) * 1000 for received, pts in selected]
    if any(value < 0 for value in latencies):
        failures.append("negative post-render submission-to-receive latency")
    processes = {}
    metrics = {}
    for label in PIPELINE + SIDECARS:
        source = sampled.get("summaries", {}).get(label)
        if source is None:
            if label in PIPELINE:
                failures.append(f"missing required process: {label}")
            continue
        if source.get("valid") is not True:
            failures.append(f"invalid process counter interval: {label}")
        rss = source.get("residentBytesMedian")
        cpu_seconds = source.get("cpuSeconds")
        records = [s.get("processes", {}).get(label, {}) for s in snapshots]
        footprints = [r["physicalFootprintBytes"] for r in records if number(r.get("physicalFootprintBytes"))]
        resolutions = [r["cpuResolutionNanoseconds"] for r in records if number(r.get("cpuResolutionNanoseconds"))]
        value = {"pid": source.get("pid"), "backend": source.get("backend"),
                 "cpuPercentOneCore": source.get("cpuPercentOneCore"), "cpuSeconds": cpu_seconds,
                 "cpuWindowSeconds": source.get("wallSeconds"),
                 "cpuResolutionNanoseconds": max(resolutions) if resolutions else None,
                 "cpuMillisecondsPerReceivedFrame": cpu_seconds * 1000 / len(selected) if number(cpu_seconds) and selected else None,
                 "residentMedianMiB": rss / 2**20 if number(rss) else None,
                 "physicalFootprintMedianMiB": statistics.median(footprints) / 2**20 if footprints else None}
        processes[label] = value
        metrics[f"cpu.{label}.percent"] = value["cpuPercentOneCore"]
        metrics[f"cpu.{label}.msPerReceivedFrame"] = value["cpuMillisecondsPerReceivedFrame"]
        metrics[f"rss.{label}.medianMiB"] = value["residentMedianMiB"]
        metrics[f"footprint.{label}.medianMiB"] = value["physicalFootprintMedianMiB"]
    pipeline_valid = all(label in processes and number(processes[label]["cpuPercentOneCore"])
                         and number(processes[label]["cpuSeconds"]) for label in PIPELINE)
    metrics["cpu.pipeline.percent"] = sum(processes[label]["cpuPercentOneCore"] for label in PIPELINE) if pipeline_valid else None
    pipeline_seconds = sum(processes[label]["cpuSeconds"] for label in PIPELINE) if pipeline_valid else None
    metrics["cpu.pipeline.msPerReceivedFrame"] = pipeline_seconds * 1000 / len(selected) if number(pipeline_seconds) and selected else None

    counters = {name: counter_delta(before, after, name) for name in
                ("submitted", "renderedFrames", "gpuTimedFrames", "gpuTimingUnavailableFrames",
                 "gpuCommandSecondsTotal", "renderWallSecondsTotal", "transportPixelCopies",
                 "queuePressureDrops", "poolPressureDrops")}
    if any(value is None for value in counters.values()):
        failures.append("missing or decreasing producer cumulative counters")
    producer_elapsed = producer_end - producer_start if number(producer_start) and number(producer_end) else None
    rendered = counters["renderedFrames"]
    gpu_valid = (number(rendered) and rendered > 0 and counters["gpuTimedFrames"] == rendered
                 and counters["gpuTimingUnavailableFrames"] == 0
                 and number(counters["gpuCommandSecondsTotal"]) and counters["gpuCommandSecondsTotal"] > 0)
    if not gpu_valid:
        warnings.append("GPU timestamps unavailable/incomplete; GPU mean is rejected, not replaced with zero")
    metrics["gpu.command.msPerFrame"] = counters["gpuCommandSecondsTotal"] * 1000 / rendered if gpu_valid else None
    metrics["render.wall.msPerFrame"] = (counters["renderWallSecondsTotal"] * 1000 / rendered
        if number(rendered) and rendered > 0 and number(counters["renderWallSecondsTotal"]) else None)
    metrics["source.fps"] = (counters["submitted"] / producer_elapsed
        if number(counters["submitted"]) and number(producer_elapsed) and producer_elapsed > 0 else None)
    metrics["receiver.fps"] = len(selected) / elapsed if selected else None
    metrics["receiver.postRenderLatency.meanMs"] = statistics.mean(latencies) if latencies else None
    metrics["receiver.postRenderLatency.p50Ms"] = percentile(latencies, .5)
    metrics["receiver.postRenderLatency.p95Ms"] = percentile(latencies, .95)
    pts_gaps = [(b[1] - a[1]) * 1000 for a, b in zip(selected, selected[1:])]
    metrics["receiver.ptsGap.p95Ms"] = percentile(pts_gaps, .95)
    metrics["receiver.ptsGap.maxMs"] = max(pts_gaps) if pts_gaps else None
    full_gaps = [(b[0] - frame_times[0][0], (b[1] - a[1]) * 1000)
                 for a, b in zip(frame_times, frame_times[1:]) if (b[1] - a[1]) > .05]
    expected_copies = 0 if entry["mode"] == "zero-copy" else rendered
    if counters["transportPixelCopies"] != expected_copies:
        failures.append("copy counter does not match mode and rendered frames")
    if ext_before.get("generation") != ext_after.get("generation"):
        failures.append("extension sink generation changed during measurement")
    extension_counters = {name: counter_delta(ext_before, ext_after, name) for name in
                         ("received", "forwarded", "rejected", "droppedNoConsumers", "consumeErrors")}
    if any(value is None for value in extension_counters.values()):
        failures.append("missing or decreasing extension cumulative counters")
    for label, count in (("queuePressureDrops", counters["queuePressureDrops"]),
                         ("poolPressureDrops", counters["poolPressureDrops"]),
                         ("extensionRejected", extension_counters["rejected"]),
                         ("extensionConsumeErrors", extension_counters["consumeErrors"]),
                         ("extensionDroppedNoConsumers", extension_counters["droppedNoConsumers"]),
                         ("consumerDroppedFramesFullCapture", capture.get("droppedFrames"))):
        if count != 0:
            warnings.append(f"{label}={count}; assess throughput before attributing lower CPU to efficiency")
    for name in ("source.fps", "receiver.fps"):
        if not number(metrics[name]) or not 29.5 <= metrics[name] <= 30.5:
            failures.append(f"{name} is outside the equal-throughput gate29.5..30.5: {metrics[name]}; CPU comparison invalid")
    if before.get("allocatedSurfaceIDs") != after.get("allocatedSurfaceIDs"):
        warnings.append("producer surface pool IDs changed during measurement")
    overhead = sampled.get("measurementOverhead", {})
    metrics["observer.cpu.percent"] = overhead.get("cpuPercentOneCore")
    thermal = {label: {"raw": report.get("thermalState"),
                       "name": THERMAL_NAMES.get(report.get("thermalState"), "unknown")}
               for label, report in (("before", before), ("after", after))}
    if any(value["raw"] != 0 for value in thermal.values()):
        warnings.append("thermal endpoints were not both nominal")
    return {"index": entry["index"], "mode": entry["mode"], "directory": str(directory),
            "status": "passed" if not failures else "invalid", "validationFailures": failures,
            "warnings": warnings, "metrics": metrics, "processes": processes,
            "pipelineCPUSeconds": pipeline_seconds,
            "windows": {"samplerStartHostSeconds": start, "samplerEndHostSeconds": end,
                        "samplerSeconds": elapsed, "producerStartHostSeconds": producer_start,
                        "producerEndHostSeconds": producer_end, "producerSeconds": producer_elapsed,
                        "producerSnapshotStartLagSeconds": start_lag, "producerSnapshotEndLagSeconds": end_lag,
                        "hostClocksAligned": aligned, "captureCoversSamplerWindow": coverage,
                        "producerWindowNote": "GPU/render/source deltas use the separately recorded producer snapshot window, not the exact CPU window"},
            "receiver": {"framesInSamplerWindow": len(selected), "fullCaptureFrames": capture.get("receivedFrames"),
                         "droppedFramesFullCapture": capture.get("droppedFrames"),
                         "nativeOutputRequested": capture.get("nativeOutputRequested"),
                         "pixelReadbackEnabled": capture.get("pixelReadbackEnabled"),
                         "cameraUniqueID": capture.get("camera", {}).get("uniqueID"),
                         "ptsGapsOver50msInSamplerWindow": sum(value > 50 for value in pts_gaps),
                         "ptsGapsOver50msInFullCapture": len(full_gaps),
                         "firstGapOver50msSecondsAfterFirstCaptureFrame": full_gaps[0][0] if full_gaps else None,
                         "latencyScope": "callback host time minus PTS stamped after source GPU completion; excludes source render/copy time"},
            "producerCounterDeltas": counters, "extensionCounterDeltas": extension_counters,
            "scratchBufferBytes": after.get("scratchBufferBytes"), "thermalEndpoints": thermal,
            "observerOverhead": overhead,
            "evidence": [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                         for path in files.values()]}


def comparisons(runs):
    metrics = sorted({key for run in runs for key in run.get("metrics", {})})
    groups = {mode: {key: stats([run["metrics"].get(key) for run in runs if run.get("metrics") and run["mode"] == mode])
                     for key in metrics} for mode in MODES}
    by_index = {run["index"]: run for run in runs}
    pairs = []
    for first in (1, 3, 5, 7):
        pair = [by_index.get(first), by_index.get(first + 1)]
        if not all(run and run.get("metrics") for run in pair) or {run["mode"] for run in pair} != set(MODES):
            continue
        copy = next(run for run in pair if run["mode"] == "gpu-copy")
        zero = next(run for run in pair if run["mode"] == "zero-copy")
        differences = {key: copy["metrics"][key] - zero["metrics"][key] for key in metrics
                       if number(copy["metrics"].get(key)) and number(zero["metrics"].get(key))}
        pairs.append({"indices": [first, first + 1], "copyRun": copy["index"], "zeroRun": zero["index"],
                      "bothRunsValid": all(run["status"] == "passed" for run in pair),
                      "copyMinusZero": differences})
    paired = {key: stats([pair["copyMinusZero"].get(key) for pair in pairs]) for key in metrics}
    effects = {}
    for key in metrics:
        copy, zero = groups["gpu-copy"][key]["mean"], groups["zero-copy"][key]["mean"]
        effects[key] = {"copyMeanMinusZeroMean": copy - zero if number(copy) and number(zero) else None,
                        "relativeDifferencePercentOfCopy": 100 * (copy - zero) / copy
                        if number(copy) and number(zero) and copy != 0 else None}
    return groups, pairs, paired, effects


def cell(summary):
    if not summary or summary["n"] == 0:
        return "unavailable"
    return f'{summary["mean"]:.4f} [{summary["min"]:.4f}, {summary["max"]:.4f}]'


def markdown(report):
    lines = ["# Native camera controlled A/B performance", "",
             f'Status: **{report["status"]}**. {report["completedRuns"]}/{report["expectedRuns"]} completed runs.', "",
             "Values below are per-run means, then mean [minimum, maximum] across runs. CPU100% means one busy core.",
             "The pipeline sum includes host + extension + consumer only. Shared camera_service, background WMC, and observer are separate.", "",
             "| Metric | Zero-copy | One GPU copy | Copy minus zero (paired mean [range]) |",
             "| --- | ---: | ---: | ---: |"]
    wanted = ["cpu.host.percent", "cpu.extension.percent", "cpu.consumer.percent", "cpu.pipeline.percent",
              "cpu.pipeline.msPerReceivedFrame", "cpu.camera_service.percent", "cpu.background_wmc.percent",
              "rss.host.medianMiB", "rss.extension.medianMiB", "rss.consumer.medianMiB",
              "footprint.host.medianMiB", "footprint.consumer.medianMiB",
              "gpu.command.msPerFrame", "render.wall.msPerFrame", "source.fps", "receiver.fps",
              "receiver.postRenderLatency.p50Ms", "receiver.postRenderLatency.p95Ms",
              "receiver.ptsGap.maxMs", "observer.cpu.percent"]
    for key in wanted:
        lines.append(f'| {key} | {cell(report["modeSummaries"]["zero-copy"].get(key))} | '
                     f'{cell(report["modeSummaries"]["gpu-copy"].get(key))} | {cell(report["pairedDifferenceSummaries"].get(key))} |')
    lines += ["", "| Run | Mode | Pipeline CPU% | GPU command ms/frame | Source fps | Receiver fps | Status |",
              "| --- | --- | ---: | ---: | ---: | ---: | --- |"]
    for run in report["runs"]:
        def value(key):
            n = run.get("metrics", {}).get(key)
            return f"{n:.4f}" if number(n) else "unavailable"
        lines.append(f'| {run["index"]} | {run["mode"]} | {value("cpu.pipeline.percent")} | '
                     f'{value("gpu.command.msPerFrame")} | {value("source.fps")} | '
                     f'{value("receiver.fps")} | {run["status"]} |')
    lines += ["", "Limits:", ""] + [f"- {note}" for note in report["interpretation"]]
    problems = [(run["index"], item) for run in report["runs"] for item in
                run.get("validationFailures", []) + run.get("warnings", [])]
    if problems:
        lines += ["", "Run observations:", ""] + [f"- Run{index}: {item}" for index, item in problems]
    else:
        lines += ["", "All completed runs passed metadata-only capture, clock overlap, format, and counter checks."]
    if report.get("excludedSeries"):
        lines += ["", "Excluded earlier series (artifacts preserved):", ""]
        lines += [f'- {item["directory"]}: {item["reason"]}' for item in report["excludedSeries"]]
    return "\n".join(lines) + "\n"


def self_test():
    # Fixed independent example verifies units/signs and balanced order, rather
    # than mocking this benchmark's actual measurements.
    example = [{"index": i, "mode": mode, "status": "passed", "metrics": {"cost": cost}}
               for i, mode, cost in [(1, "zero-copy", 10), (2, "gpu-copy", 14),
                                      (3, "gpu-copy", 12), (4, "zero-copy", 9)]]
    groups, pairs, paired, effects = comparisons(example)
    assert groups["zero-copy"]["cost"]["mean"] == 9.5
    assert [pair["copyMinusZero"]["cost"] for pair in pairs] == [4, 3]
    assert paired["cost"]["mean"] == 3.5 and effects["cost"]["copyMeanMinusZeroMean"] == 3.5
    assert percentile([1, 2, 3, 4], .5) == 2.5
    assert cmtime_seconds({"value": 3, "timescale": 2, "epoch": 0, "flags": 1}) == 1.5
    assert cmtime_seconds({"value": 3, "timescale": 0, "epoch": 0, "flags": 1}) is None
    print("PASS: fixed run means, paired orientation, percentile, invalid-clock rejection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("comparison", nargs="?", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--allow-partial", action="store_true")
    parser.add_argument("--excluded-series", type=Path, action="append", default=[],
                        help="Record a separate earlier invalid-throughput series; does not remove runs from this input")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.comparison is None:
        parser.error("COMPARISON_DIRECTORY is required")
    base = args.comparison.resolve()
    manifest_path = base / "manifest.json"
    manifest = load(manifest_path) if manifest_path.exists() else {}
    if manifest.get("checkOnly"):
        parser.error("preflight/check-only captures are not performance samples")
    entries = {int(entry["index"]): entry for entry in manifest.get("runs", [])}
    if args.allow_partial:
        for directory in sorted(base.iterdir()):
            match = re.fullmatch(r"(\d+)-(zero-copy|gpu-copy)", directory.name)
            if directory.is_dir() and match:
                index = int(match[1])
                entries.setdefault(index, {"index": index, "mode": match[2], "directory": str(directory)})
    expected = len(manifest.get("order", [])) or 8
    runs = [analyze_run(entries[index], base) for index in sorted(entries)]
    completed = [run for run in runs if run["status"] != "pending"]
    groups, pairs, paired, effects = comparisons(completed)
    invalid = any(run["status"] == "invalid" for run in completed)
    status = "invalid" if invalid else "complete" if len(completed) == expected else "partial"
    report = {"schemaVersion": 1, "status": status,
              "createdAt": datetime.now(timezone.utc).isoformat(), "comparisonDirectory": str(base),
              "manifest": manifest, "expectedRuns": expected, "completedRuns": len(completed),
              "cpuConvention": "one CPU core fully busy =100%; target sum=host+extension+consumer",
              "runs": runs, "modeSummaries": groups, "pairs": pairs,
              "pairedDifferenceSummaries": paired, "modeMeanDifferences": effects,
              "equalThroughputGateFPS": {"minimum": 29.5, "maximum": 30.5},
              "excludedSeries": [{"directory": str(path.resolve()),
                  "reason": "Earlier series aborted because producer/receiver throughput differed from the30fps target; its CPU comparison is invalid. Artifacts remain separate and were not merged into this series."}
                  for path in args.excluded_series],
              "interpretation": [
                  "Controlled synthetic source through the same native camera and consumer. Not a before/after result for stock WMC, UniCamEx, or Meet.",
                  "All complete runs contribute to summaries; no outlier or unfavorable run is silently discarded. Invalid status blocks a comparison conclusion.",
                  "A source or receiver rate outside29.5..30.5fps invalidates the CPU comparison; per-frame normalization is diagnostic and does not waive this equal-throughput gate.",
                  "Run-level mean/min/max and adjacent paired differences are descriptive;1s/5s intervals are not independent repeated experiments and no significance claim is made.",
                  "Positive copy-minus-zero values indicate lower zero-copy cost for CPU/time/memory metrics; the sign has a different meaning for fps.",
                  "GPU command time includes source rendering and the optional copy. It is elapsed command execution time, not whole-GPU utilization, energy, or isolated blit timing.",
                  "Source GPU/render means use producer cumulative counters after warm-up; their snapshot window may be offset by up to2s from CPU sampling.",
                  "Post-render receive latency is callback host time minus a PTS stamped after source GPU completion. It excludes source rendering/copy and is not full end-to-end latency.",
                  "Consumer droppedFrames is for the full capture, not only the CPU window; pressure/reject counts use producer/extension snapshot deltas.",
                  "Thermal values are endpoint snapshots, not proof of the entire interval's thermal state. Observer overhead is measured separately, not subtracted from target CPU.",
                  "footprint.* is the OS-charged physical footprint of that individual process, where proc_pid_rusage exposes it. It is not a sum of shared RSS or a whole-machine physical-memory saving.",
              ]}
    output = args.output or base / "analysis.json"
    md = args.markdown or base / "analysis.md"
    output.parent.mkdir(parents=True, exist_ok=True)
    md.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    md.write_text(markdown(report))
    print(json.dumps({"status": status, "completedRuns": len(completed), "expectedRuns": expected,
                      "json": str(output), "markdown": str(md)}, ensure_ascii=False))
    return 1 if invalid or (status == "partial" and not args.allow_partial) else 0


if __name__ == "__main__":
    raise SystemExit(main())
