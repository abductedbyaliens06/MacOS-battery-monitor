import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root/'Tools/SchedulingBenchmark'))
from analysis import integrate, summarize, percentile


def sample(t, watts=10, **extra):
    return dict(time=t, wallTime=1800000000+t, watts=watts, onBattery=True,
                source='SMC_B0AV_B0AC', lpm=False, refreshRates=[120], **extra)


def trials(power=.7, throughput=.9, latency=1):
    rows = []
    for cycle in range(3):
        order = ['baseline', 'efficient', 'efficient', 'baseline'] if cycle % 2 == 0 else ['efficient', 'baseline', 'baseline', 'efficient']
        for mode in order:
            optimized = mode == 'efficient'
            rows.append(dict(cycle=cycle, mode=mode, valid=True, duration=20,
                energy=dict(joules=200*(power if optimized else 1), coverage=1),
                chunks=1000*(throughput if optimized else 1),
                probeLatencySeconds=[.01*(latency if optimized else 1)]*100))
    return rows


class AnalysisTests(unittest.TestCase):
    def test_clipped_trapezoids(self):
        value = integrate([sample(0, 8), sample(1, 12), sample(2, 16)], .5, 1.5)
        self.assertAlmostEqual(value['joules'], 12)
        self.assertAlmostEqual(value['coverage'], 1)

    def test_missing_invalid_and_gaps_are_not_zero_power(self):
        for bad in [None, float('nan'), -10, 400, True]:
            self.assertEqual(integrate([sample(0), sample(1, bad)], 0, 1)['coverage'], 0)
        self.assertEqual(integrate([sample(0), sample(10)], 0, 10)['coverage'], 0)
        self.assertIsNone(integrate([], 0, 10)['meanWatts'])

    def test_context_and_clock_changes_break_energy_coverage(self):
        for field, value in [('onBattery', False), ('source', 'Other'), ('lpm', True), ('refreshRates', [60]), ('wallTime', 1800000010)]:
            b = sample(1); b[field] = value
            self.assertEqual(integrate([sample(0), b], 0, 1)['coverage'], 0)

    def test_watts_alone_cannot_pass(self):
        result = summarize(trials(power=.7, throughput=.5))
        self.assertEqual(result['verdict'], 'no_efficiency_gain')
        self.assertLess(result['meanPowerRatio'], 1)
        self.assertGreater(result['meanEnergyPerWorkRatio'], 1)

    def test_performance_gate(self):
        self.assertEqual(summarize(trials(latency=1.3))['verdict'], 'performance_regression')

    def test_success_stays_synthetic(self):
        result = summarize(trials())
        self.assertEqual(result['verdict'], 'promising_synthetic_pilot')
        self.assertIn('unverified', result['reason'])
        self.assertTrue(any('real apps' in x for x in result['limitations']))

    def test_abort_incomplete_and_bad_data_never_pass(self):
        self.assertEqual(summarize(trials()[:4])['verdict'], 'inconclusive')
        self.assertEqual(summarize(trials(), 'Power changed')['verdict'], 'inconclusive')
        for mutation in ['valid', 'coverage', 'chunks', 'latency']:
            rows = trials()
            for row in rows:
                if mutation == 'valid': row['valid'] = False
                if mutation == 'coverage': row['energy']['coverage'] = .8
                if mutation == 'chunks': row['chunks'] = 0
                if mutation == 'latency': row['probeLatencySeconds'] = []
            self.assertEqual(summarize(rows)['verdict'], 'inconclusive')

    def test_variable_cycles_do_not_get_pseudoreplication(self):
        rows = trials()
        for row in rows:
            if row['mode'] == 'efficient':
                row['energy']['joules'] *= [.6, 1, 1.3][row['cycle']]
        result = summarize(rows)
        self.assertEqual(result['completeCycles'], 3)
        self.assertEqual(result['verdict'], 'inconclusive')
        self.assertGreater(result['energyPerWorkRatio95CI'][1], 1)

    def test_percentile(self):
        self.assertAlmostEqual(percentile([.01, .02, .03], .95), .029)


if __name__ == '__main__':
    unittest.main()
