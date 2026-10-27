#!/usr/bin/env python3
"""Offline IOSurface/PTS correlation. Never opens cameras or changes raw evidence."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import sys
import tempfile


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def key(surface, value, scale, epoch=0):
    if not all(is_integer(n) for n in (surface, value, scale, epoch)):
        return None
    if not (0 < surface < 2**32 and 0 < scale < 2**31 and -(2**63) < value < 2**63):
        return None
    return (surface, epoch, Fraction(value, scale))


def correlate(report, trace_text, trace_path):
    """Same exact rational matching rule as the native verifier, without tolerances."""
    source = {}
    malformed = 0
    duplicates = 0
    for line in trace_text.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("source record is not an object")
        except (json.JSONDecodeError, ValueError):
            malformed += 1
            continue
        if record.get("event") != "submitted":
            continue
        match_key = key(record.get("surfaceID"), record.get("ptsValue"), record.get("ptsTimescale"))
        if match_key is None:
            malformed += 1
            continue
        if match_key in source:
            duplicates += 1
        source[match_key] = record

    matched = missing = stamp_mismatches = 0
    validate_stamp = report.get("stampValidationEnabled") is True
    for frame in report["frames"]:
        for field in ("sourceMatch", "sourceSequence", "stampMatchesSourceSequence"):
            frame.pop(field, None)
        pts = frame.get("pts", {})
        match_key = key(frame.get("surfaceID"), pts.get("value"), pts.get("timescale"), pts.get("epoch", 0))
        submitted = source.get(match_key)
        if submitted is None:
            frame["sourceMatch"] = False
            missing += 1
            continue
        frame["sourceMatch"] = True
        matched += 1
        sequence = submitted.get("sequence")
        if is_integer(sequence) and 0 <= sequence < 2**64:
            frame["sourceSequence"] = str(sequence)
            if validate_stamp:
                agrees = frame.get("stampValid") is True and frame.get("stampSequence") == str(sequence)
                frame["stampMatchesSourceSequence"] = agrees
                stamp_mismatches += not agrees
        elif validate_stamp:
            frame["stampMatchesSourceSequence"] = False
            stamp_mismatches += 1

    return {
        "requested": True,
        "path": str(trace_path),
        "sourceRecords": len(source),
        "malformedSourceLines": malformed,
        "duplicateSurfacePTSKeys": duplicates,
        "matchedFrames": matched,
        "unmatchedFrames": missing,
        "stampSequenceMismatches": stamp_mismatches,
        "matchingRule": "same IOSurface ID and exactly equal rational PTS",
        "sameSurfaceAndPTSConfirmed": bool(report["frames"]) and missing == 0
        and stamp_mismatches == 0 and malformed == 0 and duplicates == 0,
    }


def recheck(report, trace_text, trace_path):
    """Return a full copied report, retaining capture fields and reevaluating checks."""
    result = copy.deepcopy(report)
    frames = result.get("frames")
    if not isinstance(frames, list) or not all(isinstance(frame, dict) for frame in frames):
        raise ValueError("Input must be a verifier report with a frames array")
    previous_status = result.get("status")
    previous_correlation = result.get("sourceCorrelation")
    correlation = correlate(result, trace_text, trace_path)
    result["sourceCorrelation"] = correlation
    failures = []
    if result.get("error"):
        failures.append("capture_report_contains_error")
    if len(frames) < result.get("minimumFrames", 1):
        failures.append("insufficient_frames")
    if result.get("receivedFrames") != len(frames):
        failures.append("frame_count_inconsistent")
    if any(frame.get("iosurfaceBacked") is not True or not is_integer(frame.get("surfaceID"))
           or frame["surfaceID"] <= 0 for frame in frames):
        failures.append("missing_iosurface_frames")
    if result.get("pixelReadErrors", 0) != 0 or any(frame.get("pixelReadError") for frame in frames):
        failures.append("pixel_read_errors")
    checks = result.get("retentionChecks", [])
    mutations = sum(check.get("pixelsUnchanged") is not True
                    or not check.get("beforeSHA256")
                    or check.get("beforeSHA256") != check.get("afterSHA256")
                    or bool(check.get("error")) for check in checks)
    if mutations or result.get("retentionMutations", 0) != 0:
        failures.append("retained_pixels_mutated_or_unreadable")
    if result.get("retentionHoldMilliseconds", 0) > 0 and not checks:
        failures.append("requested_retention_checks_missing")
    if result.get("stampValidationEnabled") is True and any(frame.get("stampValid") is not True for frame in frames):
        failures.append("invalid_stamp_frames")
    if result.get("nativeOutputRequested") is not True:
        failures.append("native_output_not_requested")
    if correlation["sameSurfaceAndPTSConfirmed"] is not True:
        failures.append("source_surface_pts_correlation_failed")
    result["status"] = "failed" if failures else "passed"
    result["offlineRecheck"] = {
        "recheckedAt": datetime.now(timezone.utc).isoformat(),
        "previousStatus": previous_status,
        "previousSourceCorrelation": previous_correlation,
        "validationFailures": failures,
        "cameraOpened": False,
        "matchingTolerance": "none",
    }
    return result


def self_test():
    fixture = {
        "schemaVersion": 1, "status": "failed", "receivedFrames": 1, "minimumFrames": 1,
        "pixelReadErrors": 0, "retentionMutations": 0, "retentionChecks": [],
        "stampValidationEnabled": True, "nativeOutputRequested": True,
        "sourceCorrelation": {"requested": True, "error": "read permission denied", "sameSurfaceAndPTSConfirmed": False},
        "frames": [{"surfaceID": 42, "iosurfaceBacked": True,
                    "pts": {"value": 1, "timescale": 30, "epoch": 0},
                    "stampValid": True, "stampSequence": "7"}],
    }
    source = {"event": "submitted", "sequence": 7, "surfaceID": 42, "ptsValue": 100, "ptsTimescale": 3000}
    line = json.dumps(source) + "\n"
    output = recheck(fixture, line, "fixture.jsonl")
    assert output["status"] == "passed"
    assert output["offlineRecheck"]["previousSourceCorrelation"]["error"] == "read permission denied"
    assert fixture["frames"][0].get("sourceMatch") is None, "must not mutate input"
    for changed in ({"surfaceID": 43}, {"ptsValue": 101}, {"sequence": 8}):
        assert recheck(fixture, json.dumps(source | changed), "fixture.jsonl")["status"] == "failed"
    assert recheck(fixture, line + line, "fixture.jsonl")["status"] == "failed"
    assert recheck(fixture, line + "not-json\n", "fixture.jsonl")["status"] == "failed"
    assert key(42, 13_333_333, 1_000_000_000) != key(42, 1333, 100_000), "rounded PTS must fail"
    assert key(42, 13_330_000, 1_000_000_000) == key(42, 1333, 100_000), "exact quantized PTS matches"
    changed_fixture = copy.deepcopy(fixture)
    changed_fixture["retentionChecks"] = [{"pixelsUnchanged": True, "beforeSHA256": "a", "afterSHA256": "b"}]
    assert recheck(changed_fixture, line, "fixture.jsonl")["status"] == "failed"
    changed_fixture = copy.deepcopy(fixture)
    changed_fixture["error"] = "capture failed"
    assert recheck(changed_fixture, line, "fixture.jsonl")["status"] == "failed"
    print("PASS: exact rational correlation, rejected rounded PTS/ID/sequence, retained mutation, malformed/duplicate trace, preserved raw evidence")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recheck-report", type=Path)
    parser.add_argument("--source-trace", type=Path)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not all((args.recheck_report, args.source_trace, args.report)):
        parser.error("--recheck-report, --source-trace and --report are required")
    capture_path = args.recheck_report.resolve()
    trace_path = args.source_trace.resolve()
    output_path = args.report.resolve()
    if output_path in (capture_path, trace_path):
        parser.error("Use a separate output path to preserve the raw capture and source trace")
    raw_capture = capture_path.read_bytes()
    raw_trace = trace_path.read_bytes()
    result = recheck(json.loads(raw_capture), raw_trace.decode("utf-8"), trace_path)
    result["offlineRecheck"]["evidenceOrigin"] = {
        "captureReport": {"path": str(capture_path), "sha256": hashlib.sha256(raw_capture).hexdigest()},
        "sourceTrace": {"path": str(trace_path), "sha256": hashlib.sha256(raw_trace).hexdigest()},
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=output_path.parent, prefix=output_path.name + ".", suffix=".tmp", delete=False) as handle:
        temporary = Path(handle.name)
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.replace(output_path)
    correlation = result["sourceCorrelation"]
    print(f"{result['status'].upper()}: matched={correlation['matchedFrames']} unmatched={correlation['unmatchedFrames']} "
          f"stampMismatches={correlation['stampSequenceMismatches']} report={output_path}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"Offline recheck error: {error}", file=sys.stderr)
        raise SystemExit(2)
