"""用假 bao 验证失败不会推进成功时间或删除已有快照。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from jinja2 import Template

TEMPLATE = Path(__file__).resolve().parents[1] / 'roles/openbao_bootstrap/templates/bao-snapshot.sh.j2'


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.snap = self.root / 'snapshots'
        self.metrics = self.root / 'metrics'
        self.snap.mkdir()
        self.metrics.mkdir()
        self.token = self.root / 'token'
        self.token.write_text('test-only')
        self.script = self.root / 'snapshot.sh'
        self.script.write_text(Template(TEMPLATE.read_text()).render(
            ansible_managed='test', openbao_snapshot_dir=str(self.snap),
            openbao_snapshot_metrics_dir=str(self.metrics), openbao_addr='https://invalid',
            openbao_tls_dir='/unused', openbao_snapshot_keep=2,
        ).replace('/etc/openbao/snapshot.token', str(self.token)))
        bao = self.root / 'bao'
        bao.write_text('''#!/usr/bin/env bash
if [ "$1" = token ]; then
  [ "${FAIL_AT:-}" != renew ]; exit $?
fi
printf snapshot > "$5"
[ "${FAIL_AT:-}" != save ]
''')
        bao.chmod(0o755)
        for n in range(3):
            p = self.snap / f'openbao-old{n}.snap'
            p.write_text('old snapshot')
            os.utime(p, (100+n, 100+n))
        self.success = self.metrics / 'openbao_snapshot_success.prom'
        self.success.write_text('openbao_snapshot_last_success_timestamp_seconds 123\n')

    def run_snapshot(self, failure=''):
        return subprocess.run(['bash', str(self.script)], env=dict(os.environ,
            PATH=str(self.root)+':'+os.environ['PATH'], FAIL_AT=failure), capture_output=True)

    def test_renew_failure_preserves_success_and_snapshots(self):
        self.assertNotEqual(self.run_snapshot('renew').returncode, 0)
        self.check_failure()

    def test_partial_snapshot_is_removed(self):
        self.assertNotEqual(self.run_snapshot('save').returncode, 0)
        self.check_failure()
        self.assertEqual(list(self.snap.glob('*.partial')), [])

    def test_missing_token_is_reported(self):
        self.token.unlink()
        self.assertNotEqual(self.run_snapshot().returncode, 0)
        self.check_failure()

    def check_failure(self):
        self.assertEqual(self.success.read_text(), 'openbao_snapshot_last_success_timestamp_seconds 123\n')
        self.assertIn('openbao_snapshot_last_run_success 0', (self.metrics/'openbao_snapshot_result.prom').read_text())
        self.assertEqual(len(list(self.snap.glob('*.snap'))), 3)

    def test_success_retention_and_permissions(self):
        p = self.run_snapshot()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('seconds 123\n', self.success.read_text())
        self.assertIn('openbao_snapshot_last_run_success 1', (self.metrics/'openbao_snapshot_result.prom').read_text())
        snapshots = list(self.snap.glob('*.snap'))
        self.assertEqual(len(snapshots), 2)
        new = next(p for p in snapshots if 'old' not in p.name)
        self.assertEqual(new.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.success.stat().st_mode & 0o777, 0o644)


if __name__ == '__main__':
    unittest.main()
