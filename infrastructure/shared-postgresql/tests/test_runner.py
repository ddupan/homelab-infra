"""验证短期会话边界：失败不回退、子进程失败也撤销；不使用真实秘密。"""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pg_runner', Path(__file__).parents[1] / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_revoke_on_child_failure(self):
        with patch.object(runner.sys, 'argv', ['run.py', '--spiffe', 'ansible', 'credentials.yml']), \
                patch.object(runner, 'spiffe_token', return_value='test-token'), \
                patch.object(runner, 'run_command', side_effect=RuntimeError('child failed')), \
                patch.object(runner, 'bao_request') as request:
            with self.assertRaises(RuntimeError):
                runner.main()
            self.assertEqual(request.call_args.args[1:], ('auth/token/revoke-self', {}, 'test-token'))

    def test_no_fallback_after_login_failure(self):
        with patch.object(runner.sys, 'argv', ['run.py', '--spiffe', 'ansible', 'credentials.yml']), \
                patch.object(runner, 'spiffe_token', side_effect=SystemExit('login failed')), \
                patch.object(runner, 'run_command') as command:
            with self.assertRaises(SystemExit):
                runner.main()
            command.assert_not_called()

    def test_revoke_on_success_and_preserve_exit_code(self):
        with patch.object(runner.sys, 'argv', ['run.py', '--spiffe', 'ansible', 'credentials.yml']), \
                patch.object(runner, 'spiffe_token', return_value='test-token'), \
                patch.object(runner, 'run_command', return_value=7), \
                patch.object(runner, 'bao_request') as request:
            self.assertEqual(runner.main(), 7)
            request.assert_called_once()


if __name__ == '__main__':
    unittest.main()
