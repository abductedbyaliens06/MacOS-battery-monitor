"""Unprivileged pilot. Only disposable fixture processes change their OWN policy."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import threading
import time
from analysis import integrate, summarize


class Fixture:
    def __init__(self, executable, mode):
        self.process = subprocess.Popen([executable, mode], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''

    def command(self, value):
        started = time.monotonic()
        self.process.stdin.write(value.encode('ascii')); self.process.stdin.flush()
        while b'\n' not in self.buffer:
            remaining = 2 - (time.monotonic()-started)
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise RuntimeError('Disposable fixture timed out; experiment stopped.')
            chunk = os.read(self.process.stdout.fileno(), 4096)
            if not chunk:
                raise RuntimeError('Disposable fixture exited; policy test unavailable.')
            self.buffer += chunk
            if len(self.buffer) > 4096:
                raise RuntimeError('Unexpected fixture response size.')
        line, self.buffer = self.buffer.split(b'\n', 1)
        return json.loads(line), time.monotonic()-started

    def close(self):
        # EOF lets only this fixture restore its policy and exit normally.
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            # This is our disposable executable, never a discovered user process.
            self.process.terminate(); self.process.wait(timeout=3)
        if self.process.returncode != 0:
            raise RuntimeError('A fixture did not exit cleanly; result is invalid.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture'); parser.add_argument('telemetry')
    parser.add_argument('--seconds', type=int, default=20, choices=range(10, 61), metavar='10..60')
    parser.add_argument('--cycles', type=int, default=3, choices=range(1, 4), metavar='1..3')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or Path('/tmp')/('battery-scheduling-pilot-%d.json' % time.time_ns())
    if output.exists():
        parser.error('Output already exists; refusing to overwrite it.')
    report = {'schemaVersion': 1, 'method': 'Unprivileged self-policy fixture ABBA/BAAB pilot',
              'secondsPerTrial': args.seconds, 'cyclesRequested': args.cycles, 'warmupSeconds': 10,
              'samples': [], 'trials': [], 'aborted': None}
    telemetry = subprocess.Popen([args.telemetry], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    samples, first = report['samples'], threading.Event()
    stream_error = []

    def collect():
        try:
            for line in telemetry.stdout:
                if len(line) > 8192 or len(samples) >= 2400:
                    raise RuntimeError('Telemetry bounds exceeded.')
                sample = json.loads(line)
                sample['sensorTime'] = sample['time']
                # All integration boundaries use the supervisor's monotonic
                # clock; native/Swift clock origins are not assumed identical.
                sample['time'] = time.monotonic()
                samples.append(sample); first.set()
        except Exception as error:
            stream_error.append(str(error)); first.set()

    thread = threading.Thread(target=collect, daemon=True); thread.start()
    fixtures = []
    initial = None

    def guard():
        if stream_error:
            raise RuntimeError(stream_error[0])
        if not samples or time.monotonic()-samples[-1]['time'] > 2.5:
            raise RuntimeError('Battery telemetry is missing or stale.')
        sample = samples[-1]
        if sample.get('onBattery') is not True:
            raise RuntimeError('AC power connected. No battery-savings trial can run on the adapter.')
        watts = sample.get('watts')
        if type(watts) not in (float, int) or not 0 < watts <= 300:
            raise RuntimeError('Valid discharge power is unavailable; no zero-filled estimates.')
        if sample.get('thermal') not in (0, 1):
            raise RuntimeError('Elevated thermal state; disposable workload stopped.')
        if sample.get('lpm'):
            raise RuntimeError('Low Power Mode is on; turn it off manually before this comparison.')
        if initial and sample.get('refreshRates') != initial.get('refreshRates'):
            raise RuntimeError('Display refresh telemetry changed; trial stopped as confounded.')
        return sample

    try:
        if not first.wait(5):
            raise RuntimeError('Telemetry did not start. No workloads launched.')
        initial = guard().copy()
        worker = Fixture(args.fixture, '--worker'); fixtures.append(worker)
        probe = Fixture(args.fixture, '--probe'); fixtures.append(probe)
        for cycle in range(args.cycles):
            order = ['baseline', 'efficient', 'efficient', 'baseline']
            if cycle % 2:
                order = ['efficient' if mode == 'baseline' else 'baseline' for mode in order]
            for mode in order:
                guard()
                state, _ = worker.command('E' if mode == 'efficient' else 'B')
                if state['mode'] != mode:
                    raise RuntimeError('Scheduling policy acknowledgement mismatch.')
                print('Cycle %d/%d: %s · 10 s settle + %d s measurement' %
                      (cycle+1, args.cycles, mode, args.seconds), file=sys.stderr, flush=True)
                settle = time.monotonic()+10
                while time.monotonic() < settle:
                    guard(); time.sleep(.2)
                before, _ = worker.command('S'); start = time.monotonic()
                latencies = []
                while time.monotonic()-start < args.seconds:
                    guard()
                    response, latency = probe.command('P')
                    if not isinstance(response.get('computeSeconds'), (float, int)):
                        raise RuntimeError('Invalid synthetic probe response.')
                    latencies.append(latency); time.sleep(.2)
                after, _ = worker.command('S'); end = time.monotonic()
                # Wait for an endpoint-bracketing sample rather than extrapolate.
                while samples[-1]['time'] < end:
                    guard(); time.sleep(.1)
                energy = integrate(samples, start, end)
                chunks = after['chunks']-before['chunks']
                trial = {'cycle': cycle, 'mode': mode, 'duration': end-start, 'chunks': chunks,
                         'energy': energy, 'probeLatencySeconds': latencies,
                         'valid': energy['coverage'] >= .999 and chunks > 0 and len(latencies) >= 20}
                report['trials'].append(trial)
                if not trial['valid']:
                    raise RuntimeError('Incomplete energy/work/latency coverage; trial cannot support a comparison.')
    except (Exception, KeyboardInterrupt) as error:
        report['aborted'] = str(error) or 'Interrupted by user.'
    finally:
        for fixture in reversed(fixtures):
            try:
                fixture.close()
            except Exception as error:
                report['aborted'] = str(error)
        if telemetry.poll() is None:
            telemetry.terminate()  # Owned read-only collector only.
        telemetry.wait(timeout=3); thread.join(timeout=1)
        report['summary'] = summarize(report['trials'], report['aborted'])
        with output.open('x') as destination:
            json.dump(report, destination, indent=2, allow_nan=False)
        print(json.dumps({'report': str(output), 'summary': report['summary']}, indent=2))
    return 2 if report['aborted'] else 0


if __name__ == '__main__':
    sys.exit(main())
