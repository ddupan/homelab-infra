"""续签调度失败关闭测试；不会连接真实 Bao 或运行 Ansible。"""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location('renew', Path(__file__).parents[1] / 'controller/renew.py')
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class RenewalTests(unittest.TestCase):
    def execute(self, results):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / 'lock'
            success = Path(directory) / 'last-success'
            original_open = open
            response = Mock()
            response.__enter__ = Mock(return_value=response)
            response.__exit__ = Mock(return_value=False)
            with patch('builtins.open', side_effect=lambda *_: original_open(lock, 'a')), \
                    patch.object(renew.subprocess, 'run', side_effect=results) as run, \
                    patch.object(renew.urllib.request, 'urlopen', return_value=response) as revoke, \
                    patch.object(renew, 'Path', return_value=success):
                rc = renew.main()
            return rc, run.call_args_list, revoke.call_count, success.exists()

    def test_login_failure_never_changes_members(self):
        rc, calls, revokes, success = self.execute([subprocess.CompletedProcess([], 1, '', '')])
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(revokes, 0)
        self.assertFalse(success)

    def test_unhealthy_cluster_never_runs_site(self):
        rc, calls, revokes, success = self.execute([
            subprocess.CompletedProcess([], 0, 'test-only-token'),
            subprocess.CompletedProcess([], 2),
        ])
        self.assertEqual(rc, 2)
        self.assertEqual(calls[1].args[0][-1], 'verify.yml')
        self.assertEqual(len(calls), 2)
        self.assertEqual(revokes, 1)
        self.assertFalse(success)

    def test_success_checks_then_converges_and_revokes(self):
        rc, calls, revokes, success = self.execute([
            subprocess.CompletedProcess([], 0, 'test-only-token'),
            subprocess.CompletedProcess([], 0),
            subprocess.CompletedProcess([], 0),
        ])
        self.assertEqual(rc, 0)
        self.assertEqual([c.args[0][-1] for c in calls[1:]], ['verify.yml', 'site.yml'])
        self.assertEqual(revokes, 1)
        self.assertTrue(success)

    def test_site_failure_is_not_success(self):
        rc, calls, revokes, success = self.execute([
            subprocess.CompletedProcess([], 0, 'test-only-token'),
            subprocess.CompletedProcess([], 0),
            subprocess.CompletedProcess([], 2),
        ])
        self.assertEqual(rc, 2)
        self.assertEqual(revokes, 1)
        self.assertFalse(success)


if __name__ == '__main__':
    unittest.main()
