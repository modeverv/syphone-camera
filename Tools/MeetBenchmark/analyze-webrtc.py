#!/usr/bin/env python3
"""Analyze a manually exported Chromium WebRTC-internals JSON dump offline.

Reads .txt/.json or gzip files only. Does not access Chrome, a camera, network,
microphone, or a Meet room. Uses each stats object's explicit timestamp series;
never invents evenly spaced timestamps from startTime/endTime.
"""
from __future__ import annotations

import argparse
from bisect import bisect_right
from collections import Counter
from datetime import datetime, timezone
import gzip
import hashlib
import json
import math
from pathlib import Path
import statistics
from urllib.parse import urlparse


FIELDS = (
    "type", "kind", "mediaType", "ssrc", "rid", "mid", "encodingIndex", "active",
    "codecId", "mediaSourceId", "remoteId", "localId", "transportId", "selectedCandidatePairId",
    "mimeType", "payloadType", "sdpFmtpLine", "encoderImplementation", "decoderImplementation",
    "powerEfficientEncoder", "powerEfficientDecoder", "scalabilityMode", "contentType",
    "frameWidth", "frameHeight", "width", "height", "framesPerSecond", "frames",
    "framesEncoded", "framesSent", "framesReceived", "framesDecoded", "framesRendered", "framesDropped",
    "bytesSent", "headerBytesSent", "retransmittedBytesSent", "packetsSent", "retransmittedPacketsSent",
    "bytesReceived", "headerBytesReceived", "retransmittedBytesReceived", "packetsReceived", "packetsLost",
    "totalEncodeTime", "totalDecodeTime", "totalPacketSendDelay", "targetBitrate", "totalEncodedBytesTarget",
    "qualityLimitationReason", "qualityLimitationDurations", "qualityLimitationResolutionChanges",
    "nackCount", "pliCount", "firCount", "qpSum", "jitter", "roundTripTime", "fractionLost",
    "totalRoundTripTime", "roundTripTimeMeasurements", "responsesReceived", "state", "dtlsState",
    "availableOutgoingBitrate", "currentRoundTripTime", "transport", "protocol", "[codec]",
)
SOURCE_URLS = {
    "chromeSeries": "https://raw.githubusercontent.com/chromium/chromium/main/content/browser/webrtc/resources/data_series.js",
    "chromeTimestamps": "https://raw.githubusercontent.com/chromium/chromium/main/content/browser/webrtc/resources/stats_graph_helper.js",
    "chromeExport": "https://raw.githubusercontent.com/chromium/chromium/main/content/browser/webrtc/resources/dump_creator.js",
    "webRTCStats": "https://www.w3.org/TR/webrtc-stats/",
    "meetSettings": "https://support.google.com/meet/answer/9302964?co=GENIE.Platform%3DDesktop&hl=en",
}


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def normalized(value):
    if not isinstance(value, str):
        return value
    try:
        decoded = json.loads(value)
        if isinstance(decoded, (int, float, bool, dict, list)) or decoded is None:
            return decoded
    except (ValueError, TypeError):
        pass
    return value


def values(series):
    result = series.get("values", [])
    if isinstance(result, str):
        result = json.loads(result)
    if not isinstance(result, list):
        raise ValueError("stats values must be an array or a JSON-quoted array")
    return [normalized(value) for value in result]


def epoch_ms(value):
    if finite(value):
        return float(value)
    text = str(value)
    parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamps must specify a UTC offset")
    return parsed.timestamp() * 1000


def utc(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat()


def decode_peer(peer):
    stats = peer.get("stats", {})
    objects, notices = {}, []
    for key, timeline in stats.items():
        if not key.endswith("-timestamp") or not isinstance(timeline, dict):
            continue
        identity = key[:-len("-timestamp")]
        timestamps = values(timeline)
        if not timestamps or any(not finite(t) for t in timestamps):
            notices.append(f"{identity}: invalid explicit timestamps")
            continue
        if any(b <= a for a, b in zip(timestamps, timestamps[1:])):
            notices.append(f"{identity}: non-increasing timestamps")
            continue
        rows = [{"timestamp": stamp, "id": identity, "type": timeline.get("statsType")} for stamp in timestamps]
        for field in FIELDS:
            series = stats.get(identity + "-" + field)
            if not isinstance(series, dict) or "values" not in series:
                continue
            samples = values(series)
            # Date serialization truncates sub-millisecond detail; compare the
            # integer millisecond values, while retaining exact stats timestamps.
            try:
                first, last = int(epoch_ms(series["startTime"])), int(epoch_ms(series["endTime"]))
                positions = [index for index, stamp in enumerate(timestamps) if first <= int(stamp) <= last]
            except (KeyError, ValueError, TypeError):
                positions = list(range(len(timestamps))) if len(samples) == len(timestamps) else []
            if len(positions) != len(samples):
                notices.append(f"{identity}.{field}: cannot align {len(samples)} values with explicit timestamps")
                continue
            for index, value in zip(positions, samples):
                rows[index][field] = value
        objects[identity] = rows
    if not objects and stats:
        notices.append("No explicit <statsId>-timestamp series; timed analysis is unavailable. No time interpolation attempted.")
    return objects, notices


def at_time(objects, identity, stamp):
    rows = objects.get(str(identity), [])
    index = bisect_right([row["timestamp"] for row in rows], stamp) - 1
    return rows[index] if index >= 0 else {}


def delta(rows, key):
    numbers = [row.get(key) for row in rows]
    if len(numbers) < 2 or any(not finite(n) for n in numbers):
        return None
    if any(b < a for a, b in zip(numbers, numbers[1:])):
        return None
    return numbers[-1] - numbers[0]


def distribution(rows, key):
    return dict(Counter(str(row[key]) for row in rows if key in row))


def analyze_stream(identity, all_rows, objects, start, end, expected, fps_tolerance, min_seconds):
    rows = [row for row in all_rows if (start is None or row["timestamp"] >= start)
            and (end is None or row["timestamp"] <= end)]
    kind = all_rows[-1].get("kind", all_rows[-1].get("mediaType"))
    direction = all_rows[-1].get("type")
    result = {"statsId": identity, "direction": direction, "kind": kind,
              "samples": len(rows), "networkVideoConfirmed": False, "requestedTargetConfirmed": False,
              "availableWindowStartUTC": utc(all_rows[0]["timestamp"]),
              "availableWindowEndUTC": utc(all_rows[-1]["timestamp"])}
    if len(rows) < 2:
        result["reason"] = "fewer than two exact timestamp samples in the requested interval"
        return result
    seconds = (rows[-1]["timestamp"] - rows[0]["timestamp"]) / 1000
    outbound = direction == "outbound-rtp"
    frames_key = "framesSent" if outbound else "framesDecoded"
    bytes_key = "bytesSent" if outbound else "bytesReceived"
    counter_names = ("framesSent", "framesEncoded", "framesReceived", "framesDecoded", "framesRendered", "framesDropped",
                     "bytesSent", "headerBytesSent", "retransmittedBytesSent", "packetsSent", "retransmittedPacketsSent",
                     "bytesReceived", "headerBytesReceived", "retransmittedBytesReceived", "packetsReceived",
                     "totalEncodeTime", "totalDecodeTime", "totalPacketSendDelay", "qualityLimitationResolutionChanges",
                     "nackCount", "pliCount", "firCount", "qpSum")
    counters = {key: delta(rows, key) for key in counter_names if any(key in row for row in rows)}
    frames, byte_count = counters.get(frames_key), counters.get(bytes_key)
    resets = [key for key in counter_names if any(finite(a.get(key)) and finite(b.get(key)) and b[key] < a[key]
              for a, b in zip(rows, rows[1:]))]
    coverage = seconds / ((end - start) / 1000) if start is not None and end is not None else None
    window_covered = coverage is None or coverage >= .9
    network = (seconds >= min_seconds and window_covered and finite(frames) and frames > 0
               and finite(byte_count) and byte_count > 0 and not resets)
    fps = frames / seconds if finite(frames) else None
    encoded_frames = counters.get("framesEncoded")
    decoded_frames = counters.get("framesDecoded")
    encoded_fps = encoded_frames / seconds if finite(encoded_frames) else None
    active_intervals = []
    for a, b in zip(rows, rows[1:]):
        if finite(a.get(frames_key)) and finite(b.get(frames_key)) and b[frames_key] > a[frames_key]:
            active_intervals.append((a, b))
    dimensions = Counter()
    target_seconds = 0
    active_seconds = 0
    for a, b in active_intervals:
        size = (b.get("frameWidth"), b.get("frameHeight"))
        dimensions[f"{size[0]}x{size[1]}"] += 1
        span = (b["timestamp"] - a["timestamp"]) / 1000
        active_seconds += span
        if expected[0] is not None and size == expected[:2] and (a.get("frameWidth"), a.get("frameHeight")) == expected[:2]:
            target_seconds += span
    target_resolution = bool(active_intervals and expected[0] is not None and abs(target_seconds - active_seconds) < 1e-8)
    fps_matches = expected[2] is None or (finite(fps) and abs(fps - expected[2]) <= fps_tolerance)
    quality_durations = {}
    a, b = normalized(rows[0].get("qualityLimitationDurations")), normalized(rows[-1].get("qualityLimitationDurations"))
    if isinstance(a, dict) and isinstance(b, dict):
        quality_durations = {key: b[key] - a[key] for key in a.keys() & b.keys()
                             if finite(a[key]) and finite(b[key]) and b[key] >= a[key]}
    codecs = {}
    for row in rows:
        codec_id = row.get("codecId")
        codec = at_time(objects, codec_id, row["timestamp"])
        if codec_id is not None:
            codecs[str(codec_id)] = {key: codec.get(key) for key in ("mimeType", "payloadType", "sdpFmtpLine")}
    media_sources = {}
    for source_id in sorted({str(row["mediaSourceId"]) for row in rows if row.get("mediaSourceId") is not None}):
        source_rows = [row for row in objects.get(source_id, []) if rows[0]["timestamp"] <= row["timestamp"] <= rows[-1]["timestamp"]]
        if len(source_rows) < 2:
            media_sources[source_id] = {"samples": len(source_rows), "timedEvidenceAvailable": False}
            continue
        source_seconds = (source_rows[-1]["timestamp"] - source_rows[0]["timestamp"]) / 1000
        source_frames = delta(source_rows, "frames")
        media_sources[source_id] = {
            "samples": len(source_rows), "timedEvidenceAvailable": True,
            "windowStartUTC": utc(source_rows[0]["timestamp"]), "windowEndUTC": utc(source_rows[-1]["timestamp"]),
            "windowSeconds": source_seconds,
            "observedDimensions": dict(Counter(f'{row.get("width")}x{row.get("height")}' for row in source_rows)),
            "frameCounterDelta": source_frames,
            "framesPerSecondFromCounterDelta": source_frames / source_seconds if finite(source_frames) else None,
            "scope": "Chrome media-source input, not the dimensions or frame rate sent over RTP",
        }
    remote_ids = sorted({str(row["remoteId"]) for row in rows if row.get("remoteId") is not None})
    remote_reports = []
    for remote_id in remote_ids:
        record = at_time(objects, remote_id, rows[-1]["timestamp"])
        remote_reports.append({"id": remote_id, "present": bool(record), **{key: record[key] for key in
                              ("type", "packetsLost", "fractionLost", "jitter", "roundTripTime", "roundTripTimeMeasurements")
                              if key in record}})
    result.update({"windowStartUTC": utc(rows[0]["timestamp"]), "windowEndUTC": utc(rows[-1]["timestamp"]),
                   "windowStartEpochMilliseconds": rows[0]["timestamp"], "windowEndEpochMilliseconds": rows[-1]["timestamp"],
                   "windowSeconds": seconds, "requestedWindowCoverageFraction": coverage,
                   "requestedWindowCoveredAtLeast90Percent": window_covered,
                   "networkVideoConfirmed": network, "requestedTargetConfirmed": network and target_resolution and fps_matches,
                   "targetResolutionSustainedWhileSending": target_resolution,
                   "targetFPSMatched": fps_matches, "targetResolutionFractionOfSendingIntervals":
                   target_seconds / active_seconds if active_seconds and expected[0] is not None else None,
                   "observedDimensionsInSendingIntervals": dict(dimensions),
                   "actualFrameRateFromCounterDelta": fps, "encodedFrameRateFromCounterDelta": encoded_fps,
                   "payloadBitrateBitsPerSecondIncludingRetransmissions": byte_count * 8 / seconds if finite(byte_count) else None,
                   "counterDeltas": counters, "counterResetFields": resets,
                   "encodeMillisecondsPerEncodedFrame": counters["totalEncodeTime"] * 1000 / encoded_frames
                   if finite(counters.get("totalEncodeTime")) and finite(encoded_frames) and encoded_frames > 0 else None,
                   "decodeMillisecondsPerDecodedFrame": counters["totalDecodeTime"] * 1000 / decoded_frames
                   if finite(counters.get("totalDecodeTime")) and finite(decoded_frames) and decoded_frames > 0 else None,
                   "ssrcValues": distribution(rows, "ssrc"), "ridValues": distribution(rows, "rid"),
                   "activeValues": distribution(rows, "active"), "codecRecords": codecs,
                   "mediaSourceRecords": media_sources,
                   "encoderImplementations": distribution(rows, "encoderImplementation"),
                   "powerEfficientEncoderValues": distribution(rows, "powerEfficientEncoder"),
                   "scalabilityModes": distribution(rows, "scalabilityMode"),
                   "qualityLimitationReasons": distribution(rows, "qualityLimitationReason"),
                   "qualityLimitationSecondsByReason": quality_durations, "remoteReports": remote_reports,
                   "reportedFramesPerSecond": {"min": min([r["framesPerSecond"] for r in rows if finite(r.get("framesPerSecond"))], default=None),
                                               "max": max([r["framesPerSecond"] for r in rows if finite(r.get("framesPerSecond"))], default=None)}})
    return result


def analyze(dump, start=None, end=None, expected=(None, None, None), fps_tolerance=1, min_seconds=10, pc_id=None):
    connections = dump.get("PeerConnections")
    if not isinstance(connections, dict):
        raise ValueError("Expected Chromium WebRTC-internals JSON with PeerConnections; RTCStatsDump line format is not this input format")
    analyzed, notices = [], []
    for connection_id, peer in connections.items():
        if pc_id and connection_id != pc_id:
            continue
        url = urlparse(peer.get("url", ""))
        if url.hostname != "meet.google.com":
            continue
        objects, object_notices = decode_peer(peer)
        streams = []
        for identity, rows in objects.items():
            last = rows[-1]
            if last.get("type") not in ("outbound-rtp", "inbound-rtp"):
                continue
            if last.get("kind", last.get("mediaType")) != "video":
                continue
            streams.append(analyze_stream(identity, rows, objects, start, end, expected, fps_tolerance, min_seconds))
        analyzed.append({"peerConnectionId": connection_id, "rendererPidReportedByChrome": peer.get("pid"),
                         "origin": f"{url.scheme}://{url.netloc}",
                         "pageURLSHA256": hashlib.sha256(peer.get("url", "").encode()).hexdigest(),
                         "streams": streams, "notices": object_notices})
    for direction in ("outbound-rtp", "inbound-rtp"):
        matching = [s for c in analyzed for s in c["streams"] if s["direction"] == direction]
        if not matching:
            notices.append(f"No Meet {direction} video stats objects; preview/source dimensions are not network-send evidence")
    return {"schemaVersion": 1, "connections": analyzed, "notices": notices,
            "requestedWindow": {"startUTC": utc(start) if start is not None else None,
                                "endUTC": utc(end) if end is not None else None},
            "expected": {"width": expected[0], "height": expected[1], "fps": expected[2], "fpsTolerance": fps_tolerance},
            "directions": {direction: {"networkVideoConfirmed": any(s["networkVideoConfirmed"] for c in analyzed for s in c["streams"] if s["direction"] == direction),
                "requestedTargetConfirmed": any(s["requestedTargetConfirmed"] for c in analyzed for s in c["streams"] if s["direction"] == direction),
                "confirmedStatsIds": [s["statsId"] for c in analyzed for s in c["streams"] if s["direction"] == direction and s["networkVideoConfirmed"]]}
                for direction in ("outbound-rtp", "inbound-rtp")},
            "interpretation": [
                "Outbound video is confirmed only by increasing framesSent AND bytesSent across an exact-timestamp interval covering at least90% of any requested window, not by a local preview, media-source dimensions, framesEncoded alone, or active=true.",
                "Each RTP encoding/SSRC is reported separately. Simulcast frame counts are never summed into a camera frame rate.",
                "Encoded frameWidth/frameHeight may be below camera/source dimensions because Meet adapts. Maximum resolution settings do not establish actual send resolution.",
                "Byte counters include RTP payload retransmissions but exclude IP/UDP overhead. They are not whole-network interface bytes or audio/data-channel traffic.",
                "Remote-inbound reports are RTCP feedback from the remote endpoint/SFU; they do not alone prove the second participant decoded the video. A receiver-side inbound dump provides separate evidence.",
                "CPU from an entire existing browser or its shared GPU/network services is not exclusively attributable to this Meet sender. Preserve per-process identities, isolate the Meet renderer where possible, and label shared process totals.",
                "Missing counters, unsupported dump fields, or unresolved timestamp alignment are not substituted with zeros. Raw dump and timestamp boundaries remain authoritative.",
            ], "primarySources": SOURCE_URLS}


def self_test():
    t = [1700000000000, 1700000001000, 1700000002000]
    def make_series(field, samples, kind="outbound-rtp"):
        return {"startTime": utc(t[0]), "endTime": utc(t[-1]), "statsType": kind, "values": json.dumps(samples)}
    stats = {"stream-" + k: make_series(k, v) for k, v in {
        "timestamp": t, "kind": ["video"] * 3, "framesSent": [0, 30, 60], "framesEncoded": [0, 30, 60],
        "bytesSent": [0, 10000, 20000], "frameWidth": [1280] * 3, "frameHeight": [720] * 3,
        "qualityLimitationReason": ["none"] * 3}.items()}
    dump = {"PeerConnections": {"test": {"url": "https://meet.google.com/test", "pid": 123, "stats": stats}}}
    result = analyze(dump, expected=(1280, 720, 30), min_seconds=1)
    stream = result["connections"][0]["streams"][0]
    assert stream["requestedTargetConfirmed"] and stream["actualFrameRateFromCounterDelta"] == 30
    assert stream["payloadBitrateBitsPerSecondIncludingRetransmissions"] == 80000
    assert not analyze(dump, expected=(1920, 1080, 30), min_seconds=1)["directions"]["outbound-rtp"]["requestedTargetConfirmed"]
    stats["stream-framesSent"] = make_series("framesSent", [0, 0, 0])
    assert not analyze(dump, min_seconds=1)["directions"]["outbound-rtp"]["networkVideoConfirmed"]
    stats["stream-framesSent"] = make_series("framesSent", [20, 10, 40])
    assert not analyze(dump, min_seconds=1)["directions"]["outbound-rtp"]["networkVideoConfirmed"]
    del stats["stream-timestamp"]
    assert not analyze(dump, min_seconds=1)["directions"]["outbound-rtp"]["networkVideoConfirmed"]
    assert not analyze({"PeerConnections": {}})["directions"]["outbound-rtp"]["networkVideoConfirmed"]
    print("PASS: actual send counters, exact timestamps, adapted-resolution rejection, no-preview/no-frame-send/reset rejection")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", nargs="?", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--start-utc")
    parser.add_argument("--end-utc")
    parser.add_argument("--process-samples", type=Path, help="Use cumulative process sampler's exact UTC collection window")
    parser.add_argument("--pc-id")
    parser.add_argument("--expected-width", type=int)
    parser.add_argument("--expected-height", type=int)
    parser.add_argument("--expected-fps", type=float)
    parser.add_argument("--fps-tolerance", type=float, default=1)
    parser.add_argument("--minimum-seconds", type=float, default=10)
    parser.add_argument("--require-direction", choices=["outbound", "inbound"], default="outbound")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.dump or not args.output:
        parser.error("DUMP and --output are required")
    if bool(args.expected_width) != bool(args.expected_height):
        parser.error("provide both expected dimensions")
    if bool(args.start_utc) != bool(args.end_utc) or (args.process_samples and args.start_utc):
        parser.error("use either --start-utc/--end-utc or --process-samples")
    if args.minimum_seconds <= 0 or args.fps_tolerance < 0:
        parser.error("minimum-seconds must be positive and fps-tolerance nonnegative")
    if any(value is not None and (not finite(value) or value <= 0) for value in
           (args.expected_width, args.expected_height, args.expected_fps)):
        parser.error("expected dimensions and frame rate must be positive finite numbers")
    if not finite(args.minimum_seconds) or not finite(args.fps_tolerance):
        parser.error("minimum-seconds and fps-tolerance must be finite")
    raw = args.dump.read_bytes()
    data = gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw
    dump = json.loads(data)
    start, end = (epoch_ms(args.start_utc), epoch_ms(args.end_utc)) if args.start_utc else (None, None)
    sampled = None
    if args.process_samples:
        sampled = json.loads(args.process_samples.read_text())
        snapshots = sampled["snapshots"]
        # recordedAt is captured at the end of each read; recover the read's
        # beginning so the sampler and WebRTC epoch windows can be aligned.
        start = epoch_ms(snapshots[0]["recordedAt"]) - snapshots[0].get("readDurationNanoseconds", 0) / 1e6
        end = epoch_ms(snapshots[-1]["recordedAt"]) - snapshots[-1].get("readDurationNanoseconds", 0) / 1e6
    if start is not None and end <= start:
        parser.error("end must follow start")
    result = analyze(dump, start, end, (args.expected_width, args.expected_height, args.expected_fps),
                     args.fps_tolerance, args.minimum_seconds, args.pc_id)
    result["input"] = {"path": str(args.dump.resolve()), "sha256": hashlib.sha256(raw).hexdigest(),
                       "userAgent": dump.get("UserAgent")}
    if sampled:
        pids = {c["rendererPidReportedByChrome"] for c in result["connections"]}
        result["processSampling"] = {"path": str(args.process_samples.resolve()),
            "sha256": hashlib.sha256(args.process_samples.read_bytes()).hexdigest(),
            "processes": {label: {"pid": s.get("pid"), "cpuPercentOneCore": s.get("cpuPercentOneCore"),
                "matchesMeetPeerConnectionRendererPid": s.get("pid") in pids, "backend": s.get("backend"),
                "valid": s.get("valid")} for label, s in sampled.get("summaries", {}).items()},
            "note": "No browser-wide CPU total is labeled Meet-only; shared services and unrelated tabs can contribute."}
    direction = args.require_direction + "-rtp"
    needed = "requestedTargetConfirmed" if args.expected_width else "networkVideoConfirmed"
    result["status"] = "confirmed" if result["directions"][direction][needed] else "not-confirmed"
    result["requiredDirection"] = direction
    result["requiredEvidence"] = needed
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"status": result["status"], "directions": result["directions"],
                      "output": str(args.output.resolve())}, ensure_ascii=False))
    return 0 if result["status"] == "confirmed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
