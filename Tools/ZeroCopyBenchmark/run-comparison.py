#!/usr/bin/env python3
"""Run the installed native camera's controlled copy/no-copy comparison."""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
HOST = Path('/Applications/SyphonCameraExtensionProbe.app')
CONSUMER = ROOT / 'Tools/ZeroCopyVerification/build/ZeroCopyVerifier.app'
STATE = Path.home() / 'Library/Containers/com.dream-jack.syphoncamera.probe/Data/Library/Application Support/SyphonZeroCopyCamera'
HOST_ID = 'com.dream-jack.syphoncamera.probe'


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def processes():
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    return [(int(line.strip().split(None, 1)[0]), line.strip().split(None, 1)[1])
            for line in rows.splitlines() if line.strip()]


def matching_pids(name):
    return [pid for pid, path in processes() if Path(path).name == name]


def wait_for(predicate, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(.15)
    raise RuntimeError('Timed out waiting for expected live state')


def quit_host():
    if matching_pids('SyphonZeroCopyCamera'):
        subprocess.run(['osascript', '-e', f'tell application id "{HOST_ID}" to quit'], check=True)
        wait_for(lambda: not matching_pids('SyphonZeroCopyCamera'))


def launch_source(mode, duration, benchmark):
    quit_host()
    started = time.time()
    args = ['open', '-n', str(HOST), '--args', '--test-pattern', '--duration', str(duration), '--transport', mode]
    if benchmark:
        args += ['--benchmark']
    subprocess.run(args, check=True)
    def fresh():
        state = load(STATE / 'producer-status.json')
        return (state if state.get('running') and state.get('transportMode') == mode
                and state.get('benchmarkMode') == benchmark
                and (STATE / 'producer-status.json').stat().st_mtime > started else None)
    wait_for(fresh)
    return started


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--warmup', type=float, default=8)
    parser.add_argument('--duration', type=float, default=40)
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--copy-first', action='store_true', help='Swap A/B order while preserving balance')
    args = parser.parse_args()
    if not 2 <= args.warmup <= 30 or not 5 <= args.duration <= 120:
        parser.error('warmup must be2..30; duration5..120')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if matching_pids('ZeroCopyVerifier'):
        raise RuntimeError('A verifier is already running')
    modes = ['zero-copy', 'gpu-copy'] if args.check_only else [
        'zero-copy', 'gpu-copy', 'gpu-copy', 'zero-copy',
        'gpu-copy', 'zero-copy', 'zero-copy', 'gpu-copy']
    if args.copy_first:
        modes = ['gpu-copy' if mode == 'zero-copy' else 'zero-copy' for mode in modes]
    manifest = {'order': modes, 'warmupSeconds': args.warmup,
                'measurementSeconds': args.duration, 'checkOnly': args.check_only, 'runs': []}
    for index, mode in enumerate(modes, 1):
        run = out / f'{index:02d}-{mode}'
        run.mkdir(exist_ok=False)
        receiver = None
        try:
            print(f'RUN {index}/{len(modes)} {mode}: starting', flush=True)
            started = launch_source(mode, args.warmup + args.duration + 35, not args.check_only)
            capture_seconds = 6 if args.check_only else args.warmup + args.duration + 10
            capture_args = ['open', '-n', '-W', str(CONSUMER), '--args',
                '--name', 'Syphon Zero Copy Camera', '--duration', str(capture_seconds),
                '--max-frames', '6000', '--minimum-frames', '100', '--report', str(run / 'capture.json')]
            if args.check_only:
                capture_args += ['--validate-stamp', '--hash-pixels']
            receiver = subprocess.Popen(capture_args)
            consumer_pids = wait_for(lambda: matching_pids('ZeroCopyVerifier'))
            if len(consumer_pids) != 1:
                raise RuntimeError('Expected exactly one verification process')
            wait_for(lambda: load(STATE / 'extension-telemetry.json').get('sourceClients', 0) > 0
                     and (STATE / 'extension-telemetry.json').stat().st_mtime > started)
            targets = {'host': matching_pids('SyphonZeroCopyCamera')[0], 'consumer': consumer_pids[0]}
            extension = matching_pids('com.dream-jack.syphoncamera.probe.camera')
            if len(extension) != 1:
                raise RuntimeError('Expected one active camera extension process')
            targets['extension'] = extension[0]
            for label, executable in [('camera_service', 'cameracaptured'),
                                      ('background_wmc', 'Webcam Motion Receiver')]:
                pids = matching_pids(executable)
                if len(pids) == 1:
                    targets[label] = pids[0]
            if not args.check_only:
                time.sleep(args.warmup)
                shutil.copy2(STATE / 'producer-status.json', run / 'producer-before.json')
                shutil.copy2(STATE / 'extension-telemetry.json', run / 'extension-before.json')
                sampler_args = [sys.executable, str(Path(__file__).with_name('sample-processes.py')),
                    '--duration', str(args.duration), '--interval', '5',
                    '--output', str(run / 'processes.json'), '--csv', str(run / 'processes.csv')]
                for label, pid in targets.items():
                    sampler_args += ['--pid', f'{label}={pid}']
                with (run / 'sampler.log').open('w') as log:
                    subprocess.run(sampler_args, check=True, stdout=log, stderr=subprocess.STDOUT)
                shutil.copy2(STATE / 'producer-status.json', run / 'producer-after.json')
                shutil.copy2(STATE / 'extension-telemetry.json', run / 'extension-after.json')
                before = load(run / 'producer-before.json')
                after = load(run / 'producer-after.json')
                fps = (after['submitted'] - before['submitted']) / (after['hostTimeSeconds'] - before['hostTimeSeconds'])
                if not 29.5 <= fps <= 30.5:
                    raise RuntimeError(f'Unequal workload: source FPS {fps:.3f}; do not interpret CPU as improvement')
                sampled = load(run / 'processes.json')
                print('MEASURED ' + mode + ' ' + json.dumps({
                    k: round(v['cpuPercentOneCore'], 4) for k, v in sampled['summaries'].items()}), flush=True)
            receiver.wait(timeout=capture_seconds + 20)
            capture = load(run / 'capture.json')
            if capture.get('status') != 'passed' or capture.get('droppedFrames') != 0:
                raise RuntimeError('Capture validation failed; keep artifacts and investigate')
            shutil.copy2(STATE / 'producer-status.json', run / 'producer-final.json')
            if args.check_only:
                shutil.copy2(STATE / 'source-trace.jsonl', run / 'source-trace.jsonl')
                subprocess.run([sys.executable, str(ROOT / 'Tools/ZeroCopyVerification/recheck-report.py'),
                    '--recheck-report', str(run / 'capture.json'), '--source-trace', str(run / 'source-trace.jsonl'),
                    '--report', str(run / 'verified.json')], check=True)
            manifest['runs'].append({'index': index, 'mode': mode, 'directory': str(run), 'pids': targets})
            (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
            print(f'DONE {index}/{len(modes)} {mode}: {capture["receivedFrames"]}frames', flush=True)
        finally:
            quit_host()
            # The verifier has a bounded lifetime; preserve its report on errors.
            if receiver and receiver.poll() is None:
                receiver.wait(timeout=args.warmup + args.duration + 30)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
