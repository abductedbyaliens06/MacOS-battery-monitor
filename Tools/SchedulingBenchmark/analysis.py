"""Analysis for counterbalanced, whole-Mac battery measurements.

A synthetic probe is not evidence of performance in real coding/video/editing.
Unknown brightness/ProMotion rates remain limitations, never filled-in data.
"""
import math
import statistics


def integrate(samples, start, end):
    """Trapezoidal integration, clipped to the actual trial interval."""
    joules = covered = 0.0
    for a, b in zip(samples, samples[1:]):
        dt = b['time'] - a['time']
        left, right = max(start, a['time']), min(end, b['time'])
        if not (0 < dt <= 2.5 and left < right):
            continue
        if abs((b['wallTime']-a['wallTime'])-dt) > 0.5:
            continue
        if any(s.get('onBattery') is not True or s.get('source') != a.get('source')
               or type(s.get('watts')) not in (float, int)
               or not math.isfinite(s['watts']) or not 0 < s['watts'] <= 300 for s in (a, b)):
            continue
        if a.get('lpm') != b.get('lpm') or a.get('refreshRates') != b.get('refreshRates'):
            continue
        x = a['watts'] + (b['watts']-a['watts']) * (left-a['time']) / dt
        y = a['watts'] + (b['watts']-a['watts']) * (right-a['time']) / dt
        duration = right-left
        covered += duration
        joules += duration*(x+y)/2
    duration = end-start
    return {'joules': joules, 'coverage': covered/duration if duration > 0 else 0,
            'coveredSeconds': covered, 'meanWatts': joules/covered if covered > 0 else None}


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered)-1)*fraction
    lo, hi = math.floor(position), math.ceil(position)
    return ordered[lo] + (ordered[hi]-ordered[lo])*(position-lo)


def confidence_interval(values):
    # Paired CYCLE ratios are independent units, not per-second samples.
    if len(values) < 3:
        return None
    n = len(values)
    critical = {2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
                7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201}.get(n-1)
    # Supported runs contain at most three cycles; other counts are inconclusive.
    if critical is None:
        return None
    margin = critical*statistics.stdev(values)/math.sqrt(n)
    mean = statistics.mean(values)
    return [mean-margin, mean+margin]


def summarize(trials, aborted=None):
    result = {'verdict': 'inconclusive', 'reason': aborted or 'Need three complete counterbalanced cycles.',
              'limitations': ['Synthetic foreground latency does not verify 90% performance in real apps.',
                             'Brightness is unmeasured; automatic brightness and ambient changes can confound energy.',
                             'A zero refresh-rate reading is unavailable telemetry, not proof of an unchanged refresh rate.',
                             'Whole-Mac energy includes unrelated activity; this is a pilot, not a battery-life guarantee.']}
    cycles = sorted(set(t['cycle'] for t in trials))
    power_ratios, energy_ratios, latency_ratios, work_ratios = [], [], [], []
    for cycle in cycles:
        rows = [t for t in trials if t['cycle'] == cycle]
        if len(rows) != 4 or any(not t['valid'] for t in rows):
            continue
        baseline = [t for t in rows if t['mode'] == 'baseline']
        efficient = [t for t in rows if t['mode'] == 'efficient']
        if len(baseline) != 2 or len(efficient) != 2:
            continue
        expected = ['baseline', 'efficient', 'efficient', 'baseline'] if cycle % 2 == 0 else ['efficient', 'baseline', 'baseline', 'efficient']
        if [t['mode'] for t in rows] != expected:
            continue
        def usable(t):
            positive = [t['duration'], t['energy']['joules'], t['chunks'], *t['probeLatencySeconds']]
            return (len(t['probeLatencySeconds']) >= 20 and .999 <= t['energy']['coverage'] <= 1.000001
                    and all(type(x) in (float, int) and math.isfinite(x) and x > 0 for x in positive))
        if not all(usable(t) for t in rows):
            continue
        def metrics(group):
            duration = sum(t['duration'] for t in group)
            joules = sum(t['energy']['joules'] for t in group)
            chunks = sum(t['chunks'] for t in group)
            latency = percentile([x for t in group for x in t['probeLatencySeconds']], .95)
            return joules/duration, joules/chunks, chunks/duration, latency
        b, e = metrics(baseline), metrics(efficient)
        power_ratios.append(e[0]/b[0]); energy_ratios.append(e[1]/b[1])
        work_ratios.append(e[2]/b[2]); latency_ratios.append(b[3]/e[3])
    result['completeCycles'] = len(power_ratios)
    if not power_ratios:
        return result
    result.update({'meanPowerRatio': statistics.mean(power_ratios),
                   'meanEnergyPerWorkRatio': statistics.mean(energy_ratios),
                   'meanBackgroundThroughputRatio': statistics.mean(work_ratios),
                   'meanSyntheticLatencyRetention': statistics.mean(latency_ratios),
                   'powerRatio95CI': confidence_interval(power_ratios),
                   'energyPerWorkRatio95CI': confidence_interval(energy_ratios),
                   'syntheticLatencyRetention95CI': confidence_interval(latency_ratios)})
    if aborted or len(power_ratios) < 3:
        return result
    if result['meanEnergyPerWorkRatio'] >= 1:
        result.update(verdict='no_efficiency_gain', reason='Reduced power did not improve whole-Mac energy per completed background work.')
    elif result['meanSyntheticLatencyRetention'] < .9:
        result.update(verdict='performance_regression', reason='The synthetic foreground latency gate failed.')
    elif result['powerRatio95CI'][1] < 1 and result['energyPerWorkRatio95CI'][1] < 1 and result['syntheticLatencyRetention95CI'][0] >= .9:
        result.update(verdict='promising_synthetic_pilot', reason='Pilot gates passed. Real workload performance and battery-life benefits remain unverified.')
    else:
        result['reason'] = 'Variation is too large to establish a power/energy gain with the synthetic latency gate.'
    return result
