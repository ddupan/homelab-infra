"""验证切换预检：只有唯一 Leader、候选同步、同一时间线且落后不超限时才放行。"""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('pg_switchover', Path(__file__).parents[1] / 'switchover.py')
switchover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(switchover)


def cluster(**laptop):
    return {
        'pg-laptop': {'Member': 'pg-laptop', 'Host': '192.168.10.127', 'Role': 'Replica',
                      'State': 'streaming', 'TL': 10, 'Receive Lag': 0, 'Replay Lag': 0, **laptop},
        'pg-pve1': {'Member': 'pg-pve1', 'Host': '10.60.0.20', 'Role': 'Leader',
                    'State': 'running', 'TL': 10},
    }


class PreflightTests(unittest.TestCase):
    def test_healthy_replica_passes(self):
        self.assertEqual(switchover.preflight(cluster(), 'pg-laptop'), 'pg-pve1')

    def test_refuses(self):
        cases = {
            'candidate already leader': (cluster(), 'pg-pve1'),
            'unknown member': (cluster(), 'pg-nope'),
            'not streaming': (cluster(State='starting'), 'pg-laptop'),
            'timeline mismatch': (cluster(TL=9), 'pg-laptop'),
            'lagging': (cluster(**{'Replay Lag': switchover.MAX_LAG_BYTES + 1}), 'pg-laptop'),
            'two leaders': (cluster(Role='Leader'), 'pg-laptop'),
        }
        for name, (members, candidate) in cases.items():
            with self.subTest(name), self.assertRaises(SystemExit):
                switchover.preflight(members, candidate)


if __name__ == '__main__':
    unittest.main()
