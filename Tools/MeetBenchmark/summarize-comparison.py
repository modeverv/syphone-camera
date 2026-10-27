#!/usr/bin/env python3
"""Summarize four saved ABBA windows; reads files only, never samples processes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import statistics


MIB = 1024 * 1024
METRIC_LABELS = {
    "cpu_host": ("Host CPU", "% of one core"),
    "cpu_extension": ("Camera Extension CPU", "% of one core"),
    "cpu_wmc": ("WMC CPU", "% of one core"),
    "cpu_meet_a": ("Meet A renderer CPU", "% of one core"),
    "cpu_meet_b": ("Meet B renderer CPU", "% of one core"),
    "cpu_meet_renderers": ("Meet A+B renderer CPU", "% of one core"),
    "cpu_chrome_core": ("Selected shared Chrome services CPU", "% of one core"),
    "cpu_meet_and_chrome_core": ("Meet A+B + selected Chrome services CPU", "% of one core"),
    "cpu_selected_with_wmc": ("All selected process CPU (includes WMC)", "% of one core"),
    "cpu_selected_without_wmc": ("Selected process CPU excluding WMC", "% of one core"),
    "system_cpu_busy_all_cores": ("Whole Mac CPU busy", "% of all cores"),
    "system_cpu_busy_one_core_equivalent": ("Whole Mac CPU, one-core equivalent", "% of one core"),
    "host_physical_footprint_mib": ("Host physical footprint (within-run median)", "MiB"),
    "output_fps": ("Submitted output cadence", "fps"),
    "fresh_conversion_fps": ("Fresh GPU-converted frames", "fps"),
    "repeated_output_fps": ("Repeated owned output frames", "fps"),
    "repeat_percent": ("Repeated output fraction", "%"),
    "gpu_ms_per_fresh_frame": ("Producer GPU command time / fresh frame", "ms/frame"),
    "gpu_ms_per_output_frame": ("Producer GPU command time / output frame", "ms/frame"),
    "gpu_ms_per_second": ("Producer GPU command time / status-clock second", "ms/s"),
}


def load(path):
    raw = path.read_bytes()
    return json.loads(raw), {"path": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest()}


def describe(values):
    valid = [value for value in values if value is not None]
    return {"count": len(valid), "mean": statistics.mean(valid) if valid else None,
            "minimum": min(valid) if valid else None, "maximum": max(valid) if valid else None,
            "values": values}


def change(baseline, lower):
    if baseline is None or lower is None:
        return {"reduction1080Minus720": None, "relativeReductionPercent": None}
    return {"reduction1080Minus720": baseline - lower,
            "relativeReductionPercent": 100 * (baseline - lower) / baseline if baseline != 0 else None}


def read_run(directory, designation):
    directory = directory.resolve()
    loaded, evidence = {}, {}
    for filename in ("cpu.json", "manifest.json", "summary.json", "producer-before.json", "producer-after.json"):
        loaded[filename], evidence[filename] = load(directory / filename)
    cpu, manifest, summary = loaded["cpu.json"], loaded["manifest.json"], loaded["summary.json"]
    before, after = loaded["producer-before.json"], loaded["producer-after.json"]
    if any(item.get("status") != "complete" for item in (cpu, manifest, summary)):
        raise ValueError(f"{directory.name}: input window is not complete")
    if summary.get("failures"):
        raise ValueError(f"{directory.name}: window reports failures")
    dimensions = manifest["expectedCameraResolution"]
    resolution = "1080p" if (dimensions["width"], dimensions["height"]) == (1920, 1080) else "720p" if (dimensions["width"], dimensions["height"]) == (1280, 720) else None
    if resolution is None or dimensions["fps"] != 30:
        raise ValueError(f"{directory.name}: expected a 1080p30 or 720p30 window")
    snapshots = cpu["snapshots"]
    if len(snapshots) < 2:
        raise ValueError(f"{directory.name}: insufficient raw CPU snapshots")
    process = {}
    seen_pids = set()
    for label in snapshots[0]["processes"]:
        rows = [snapshot["processes"][label] for snapshot in snapshots]
        first, last = rows[0], rows[-1]
        if any("error" in row or row["pid"] != first["pid"] or row["identity"] != first["identity"] for row in rows):
            raise ValueError(f"{directory.name}: unstable or unavailable process {label}")
        if first["pid"] in seen_pids:
            raise ValueError(f"{directory.name}: duplicated PID would double-count CPU")
        seen_pids.add(first["pid"])
        if any(b["cpuNanoseconds"] < a["cpuNanoseconds"] or b["readMonotonicNS"] <= a["readMonotonicNS"] for a, b in zip(rows, rows[1:])):
            raise ValueError(f"{directory.name}: CPU counters/time reset for {label}")
        elapsed = (last["readMonotonicNS"] - first["readMonotonicNS"]) / 1e9
        seconds = (last["cpuNanoseconds"] - first["cpuNanoseconds"]) / 1e9
        footprint = [row["physicalFootprintBytes"] for row in rows if row.get("physicalFootprintBytes") is not None]
        process[label] = {"pid": first["pid"], "identity": first["identity"], "backend": first["backend"],
            "cpuSeconds": seconds, "wallSeconds": elapsed, "cpuPercentOneCore": 100 * seconds / elapsed,
            "cpuTimeResolutionNanoseconds": max(row.get("cpuResolutionNanoseconds", 0) for row in rows),
            "physicalFootprintBytes": {"availableSamples": len(footprint), "totalSamples": len(rows),
                "median": statistics.median(footprint) if footprint else None,
                "minimum": min(footprint) if footprint else None, "maximum": max(footprint) if footprint else None}}
    groups = manifest.get("groups", {})
    role_labels = {role: groups.get(role) or ([role] if role in process else []) for role in ("host", "extension", "wmc")}
    role_labels["meet_renderers"] = [label for label in process if label.startswith("meet_")]
    role_labels["chrome_core"] = [label for label in process if label.startswith("chrome_")]
    def cpu_sum(labels):
        return sum(process[label]["cpuPercentOneCore"] for label in labels) if labels else None
    metrics = {"cpu_" + role: cpu_sum(labels) for role, labels in role_labels.items()}
    for label in ("meet_a", "meet_b"):
        metrics["cpu_" + label] = process.get(label, {}).get("cpuPercentOneCore")
    metrics["cpu_meet_and_chrome_core"] = cpu_sum(role_labels["meet_renderers"] + role_labels["chrome_core"])
    metrics["cpu_selected_with_wmc"] = cpu_sum(list(process))
    metrics["cpu_selected_without_wmc"] = cpu_sum([label for label in process if label not in role_labels["wmc"]])
    system_rows = [snapshot.get("systemCPU", {}) for snapshot in snapshots]
    if all(row.get("available") for row in system_rows):
        tick_deltas = {key: sum((b["ticks"][key] - a["ticks"][key]) & 0xffffffff for a, b in zip(system_rows, system_rows[1:])) for key in ("user", "system", "idle", "nice")}
        total_ticks = sum(tick_deltas.values())
        system_busy = 100 * (total_ticks - tick_deltas["idle"]) / total_ticks if total_ticks else None
        counts = {row.get("cpuCount") for row in system_rows}
        core_count = next(iter(counts)) if len(counts) == 1 else None
    else:
        system_busy, core_count, tick_deltas = None, None, None
    metrics["system_cpu_busy_all_cores"] = system_busy
    metrics["system_cpu_busy_one_core_equivalent"] = system_busy * core_count if system_busy is not None and core_count else None
    host_labels = role_labels["host"]
    host_footprint = process[host_labels[0]]["physicalFootprintBytes"]["median"] if len(host_labels) == 1 else None
    metrics["host_physical_footprint_mib"] = host_footprint / MIB if host_footprint is not None else None
    status_seconds = after["hostTimeSeconds"] - before["hostTimeSeconds"]
    counters = {}
    for key in ("freshRenderedFrames", "repeatedOutputFrames", "totalOutputFrames", "submitted", "renderedFrames",
                "gpuCommandSecondsTotal", "gpuTimedFrames", "gpuTimingUnavailableFrames", "transportPixelCopies",
                "sourceTransformPasses", "cpuPixelCopies", "poolPressureDrops", "queuePressureDrops"):
        counters[key] = after[key] - before[key] if key in before and key in after else None
    if status_seconds <= 0 or any(value < 0 for value in counters.values() if value is not None):
        raise ValueError(f"{directory.name}: producer counters/time reset")
    fresh, repeated, output = (counters[key] for key in ("freshRenderedFrames", "repeatedOutputFrames", "totalOutputFrames"))
    if None in (fresh, repeated, output) or output <= 0 or fresh + repeated != output or counters["submitted"] != output:
        raise ValueError(f"{directory.name}: fresh + repeated != output or output != submitted")
    gpu_ms = counters["gpuCommandSecondsTotal"] * 1000 if counters["gpuCommandSecondsTotal"] is not None else None
    metrics.update(output_fps=output / status_seconds, fresh_conversion_fps=fresh / status_seconds,
        repeated_output_fps=repeated / status_seconds, repeat_percent=100 * repeated / output,
        gpu_ms_per_fresh_frame=gpu_ms / fresh if gpu_ms is not None and fresh else None,
        gpu_ms_per_output_frame=gpu_ms / output if gpu_ms is not None else None,
        gpu_ms_per_second=gpu_ms / status_seconds if gpu_ms is not None else None)
    return {"designation": designation, "directory": str(directory), "resolution": resolution,
        "startedAt": cpu["startedAt"], "finishedAt": cpu["finishedAt"], "cpuWindowSeconds": cpu["actualWallSeconds"],
        "producerStatusWindowSeconds": status_seconds, "sourceKind": before.get("sourceKind"),
        "transportMode": before.get("transportMode"),
        "sourceDimensions": [before.get("sourceWidth"), before.get("sourceHeight")],
        "thermalStateBefore": before.get("thermalState"), "thermalStateAfter": after.get("thermalState"),
        "metrics": metrics, "processes": process, "aggregateMembership": role_labels,
        "systemTickDeltas": tick_deltas, "cpuCount": core_count, "producerCounterDeltas": counters,
        "pool": {"limit": before.get("poolLimit"), "surfaceCountBefore": len(before.get("allocatedSurfaceIDs", [])),
            "surfaceCountAfter": len(after.get("allocatedSurfaceIDs", [])),
            "surfaceSetUnchangedWithinWindow": set(before.get("allocatedSurfaceIDs", [])) == set(after.get("allocatedSurfaceIDs", [])),
            "cachedOutputBufferCountBefore": before.get("cachedOutputBufferCount"), "cachedOutputBufferCountAfter": after.get("cachedOutputBufferCount"),
            "scratchBufferBytesBefore": before.get("scratchBufferBytes"), "scratchBufferBytesAfter": after.get("scratchBufferBytes")},
        "inputEvidence": evidence}


def verify_frozen_manifest(path):
    if path is None:
        return None
    manifest, evidence = load(path)
    root = Path(__file__).resolve().parents[2]
    matches = {}
    for filename, expected in manifest.get("files", {}).items():
        source = root / filename
        actual = hashlib.sha256(source.read_bytes()).hexdigest() if source.is_file() else None
        matches[filename] = {"expectedSHA256": expected, "currentSHA256": actual, "matches": actual == expected}
    return {**evidence, "recordedAt": manifest.get("recordedAt"), "hostBuild": manifest.get("hostBuild"),
        "extensionBuild": manifest.get("extensionBuild"), "installedHostSHA256Recorded": manifest.get("installedHostSHA256"),
        "allCurrentSourceHashesMatch": bool(matches) and all(value["matches"] for value in matches.values()),
        "sourceFiles": matches,
        "scope": "Checks present source files against the frozen manifest; does not revalidate a running executable"}


def fixed_workload_errors(runs):
    errors = []
    for run in runs:
        metrics, counters = run["metrics"], run["producerCounterDeltas"]
        for key in ("output_fps", "fresh_conversion_fps"):
            if not 29.5 <= metrics[key] <= 30.5:
                errors.append(f"{run['designation']}: {key} is outside 29.5..30.5")
        if counters["repeatedOutputFrames"] != 0:
            errors.append(f"{run['designation']}: repeated outputs are present")
        if counters["gpuTimingUnavailableFrames"] != 0:
            errors.append(f"{run['designation']}: GPU timing is incomplete")
        if not (counters["gpuTimedFrames"] == counters["freshRenderedFrames"] == counters["sourceTransformPasses"] == counters["totalOutputFrames"]):
            errors.append(f"{run['designation']}: GPU transformations/timed frames/output count do not match")
    if len({(run["sourceKind"], run["transportMode"], tuple(run["sourceDimensions"])) for run in runs}) != 1:
        errors.append("Source kind, source dimensions or transport mode changed across runs")
    return errors


def comparison(runs, frozen, fixed_workload=False):
    if [run["resolution"] for run in runs] != ["1080p", "720p", "720p", "1080p"]:
        raise ValueError("Provide four directories in ABBA order: 1080p, 720p, 720p, 1080p")
    fixed_errors = fixed_workload_errors(runs)
    if fixed_workload and fixed_errors:
        raise ValueError("Fixed-workload assertion failed: " + "; ".join(fixed_errors))
    workload_note = (
        "All four windows have 29.5..30.5 submitted frames and GPU transformations per second, zero repeated outputs, and GPU timing for every transformed output. The earlier varying-transformation-cadence confound does not apply to these windows."
        if not fixed_errors else
        "Fresh GPU transformation cadence varies while owned-buffer repeats maintain output cadence. CPU changes and GPU time/output or time/second cannot be attributed to resolution alone; time/fresh transformation is reported separately."
    )
    metrics = list(METRIC_LABELS)
    conditions = {resolution: {key: describe([run["metrics"].get(key) for run in runs if run["resolution"] == resolution]) for key in metrics}
                  for resolution in ("1080p", "720p")}
    pairs = [{"pair": name, "baseline": runs[a]["designation"], "lowerResolution": runs[b]["designation"],
              "metrics": {key: change(runs[a]["metrics"].get(key), runs[b]["metrics"].get(key)) for key in metrics}}
             for name, a, b in (("A1-B2", 0, 1), ("A4-B3", 3, 2))]
    process_conditions = {}
    for label in sorted(set.intersection(*(set(run["processes"]) for run in runs))):
        process_conditions[label] = {resolution: {
            "cpuPercentOneCore": describe([run["processes"][label]["cpuPercentOneCore"] for run in runs if run["resolution"] == resolution]),
            "physicalFootprintBytesWithinRunMedian": describe([run["processes"][label]["physicalFootprintBytes"]["median"] for run in runs if run["resolution"] == resolution])}
            for resolution in ("1080p", "720p")}
    return {"schemaVersion": 1, "createdAt": datetime.now(timezone.utc).isoformat(), "status": "summarized",
        "design": "ABBA, two CPU windows per resolution, descriptive observations only",
        "fixedWorkloadValidation": {"required": fixed_workload, "passed": not fixed_errors, "errors": fixed_errors,
            "requirements": "Output and GPU transformation FPS 29.5..30.5; no repeated outputs; complete GPU timing; same upstream dimensions/source kind/transport mode; raw CPU counters and process identities valid"},
        "runs": runs, "conditionMetrics": conditions, "processConditionMetrics": process_conditions,
        "conditionMeanReductions": {key: change(conditions["1080p"][key]["mean"], conditions["720p"][key]["mean"]) for key in metrics},
        "orientedPairs": pairs, "metricDefinitions": {key: {"label": label, "unit": unit} for key, (label, unit) in METRIC_LABELS.items()},
        "frozenBuildEvidence": frozen, "actualNetworkSendingVerified": False,
        "limitations": [
            "N=2 windows per condition is not a statistical significance test or a causal isolation of resolution.",
            "Meet A+B includes sender and receiver on the same Mac; PID roles are not inferred from labels.",
            "Selected Chrome main/GPU/network/storage/audio/capture services also serve unrelated user work; this is not whole-Chrome or Meet-only CPU.",
            "Whole Mac CPU includes all background work and is independent of selected-process CPU sums.",
            "Fresh GPU transformation counts are not an independent upstream unique-image/FPS measurement: hasNewFrame notifications can coalesce and WMC publishes mutable image storage.",
            workload_note,
            "Producer GPU command time is not system GPU utilization, Chrome encoding time, or end-to-end latency.",
            "Physical footprint is per process from proc_pid_rusage; RSS/shared mappings are not summed. No whole-Mac memory saving is established.",
            "Producer counter boundaries use host-written status snapshots and differ from CPU boundaries by approximately one status interval.",
            "Actual transmitted resolution, encoded FPS and bitrate remain pending a time-aligned WebRTC-internals dump."]}


def format_number(value, digits=3):
    return "unavailable" if value is None else f"{value:.{digits}f}"


def markdown(report):
    whole_a = report["conditionMetrics"]["1080p"]["system_cpu_busy_all_cores"]["mean"]
    whole_b = report["conditionMetrics"]["720p"]["system_cpu_busy_all_cores"]["mean"]
    whole_observation = (f"Whole-Mac mean CPU busy was {format_number(whole_a)}% at 1080p and {format_number(whole_b)}% at 720p. " +
                         ("These windows do not show lower whole-Mac CPU at 720p." if whole_a is not None and whole_b is not None and whole_b >= whole_a else "This is an observed mean, not a causal or statistically established improvement."))
    lines = ["# 1080p30 / 720p30 ABBA CPU comparison", "",
        "Four recorded windows, two per condition. CPU percentages for processes use 100% = one fully busy core; whole-Mac CPU uses a separate 0–100% scale.", "",
        whole_observation, "",
        f"Fixed 30fps GPU workload validation: {'PASS' if report['fixedWorkloadValidation']['passed'] else 'not established'}. This does not measure independent upstream unique-image cadence.", "",
        "| Metric | Unit | 1080p mean [min, max] | 720p mean [min, max] | 1080−720 | Relative reduction |",
        "| --- | --- | ---: | ---: | ---: | ---: |"]
    for key, (label, unit) in METRIC_LABELS.items():
        cells = []
        for resolution in ("1080p", "720p"):
            item = report["conditionMetrics"][resolution][key]
            cells.append(f"{format_number(item['mean'])} [{format_number(item['minimum'])}, {format_number(item['maximum'])}]")
        delta = report["conditionMeanReductions"][key]
        lines.append(f"| {label} | {unit} | {cells[0]} | {cells[1]} | {format_number(delta['reduction1080Minus720'])} | {format_number(delta['relativeReductionPercent'])}% |")
    lines += ["", "A positive reduction means the 720p value was lower. A negative reduction means it was higher. FPS reductions are descriptive, not a performance benefit.", "",
        "## Per-window source cadence and GPU work", "",
        "| Run | CPU window s | Producer status window s | Output fps | Fresh fps | Repeats | GPU ms/fresh | GPU ms/output | GPU ms/s | Whole-Mac CPU % | Host footprint MiB |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for run in report["runs"]:
        m = run["metrics"]
        values = [run["cpuWindowSeconds"], run["producerStatusWindowSeconds"], m["output_fps"], m["fresh_conversion_fps"],
                  run["producerCounterDeltas"]["repeatedOutputFrames"], m["gpu_ms_per_fresh_frame"], m["gpu_ms_per_output_frame"],
                  m["gpu_ms_per_second"], m["system_cpu_busy_all_cores"], m["host_physical_footprint_mib"]]
        lines.append(f"| {run['designation']} {run['resolution']} | " + " | ".join(format_number(value) for value in values) + " |")
    lines += ["", "## Oriented pair reductions (1080p minus adjacent 720p)", "",
        "| Metric | A1−B2 | A4−B3 |", "| --- | ---: | ---: |"]
    for key, (label, unit) in METRIC_LABELS.items():
        pair = [format_number(item["metrics"][key]["reduction1080Minus720"]) for item in report["orientedPairs"]]
        lines.append(f"| {label} ({unit}) | {pair[0]} | {pair[1]} |")
    lines += ["", "## Scope and uncertainty", ""] + [f"- {item}" for item in report["limitations"]]
    lines += ["", "Pool accounting: " + "; ".join(f"{run['designation']} {run['pool']['surfaceCountBefore']}→{run['pool']['surfaceCountAfter']} surfaces (limit {run['pool']['limit']}), cached output {run['pool']['cachedOutputBufferCountAfter']}" for run in report["runs"]) + ". No RSS or per-process footprints are summed."]
    frozen = report.get("frozenBuildEvidence")
    if frozen:
        lines += ["", f"Frozen build source hashes: {'all match' if frozen['allCurrentSourceHashesMatch'] else 'MISMATCH or unavailable'}; host build {frozen['hostBuild']}, extension build {frozen['extensionBuild']}."]
    lines += ["", "## Raw inputs", ""] + [f"- `{run['designation']}`: `{run['directory']}`; {run['startedAt']} → {run['finishedAt']}" for run in report["runs"]]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs=4, type=Path, metavar="RUN_DIRECTORY")
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--output-markdown", type=Path, required=True)
    parser.add_argument("--build-manifest", type=Path)
    parser.add_argument("--fixed-workload", action="store_true", help="Require 30fps GPU transformations/output, zero repeats and complete GPU timing")
    args = parser.parse_args()
    for output in (args.output_json, args.output_markdown):
        if output.exists():
            parser.error(f"Refusing to overwrite existing result: {output}")
    runs = [read_run(path, name) for path, name in zip(args.runs, ("A1", "B2", "B3", "A4"))]
    report = comparison(runs, verify_frozen_manifest(args.build_manifest), fixed_workload=args.fixed_workload)
    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_markdown.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    args.output_markdown.write_text(markdown(report))
    print(json.dumps({"status": report["status"], "outputJSON": str(args.output_json), "outputMarkdown": str(args.output_markdown),
                      "conditionMeanReductions": report["conditionMeanReductions"]}, indent=2))


if __name__ == "__main__":
    main()
