"""Integration smoke check: change only an owned disposable fixture's policy."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'Tools/SchedulingBenchmark'))
from run import Fixture

worker = Fixture(sys.argv[1], '--worker')
try:
    probe = Fixture(sys.argv[1], '--probe')
    try:
        assert worker.command('B')[0]['mode'] == 'baseline'
        assert worker.command('E')[0]['mode'] == 'efficient'
        assert worker.command('S')[0]['mode'] == 'efficient'
        assert probe.command('P')[0]['computeSeconds'] > 0
        assert worker.command('B')[0]['mode'] == 'baseline'
        # Leave a real change active: EOF must restore it and exit cleanly.
        assert worker.command('E')[0]['mode'] == 'efficient'
    finally:
        probe.close()
finally:
    worker.close()
print('Disposable benchmark fixtures: real self-policy changes/read-back/restore, synthetic probe, and active-policy EOF cleanup passed.')
