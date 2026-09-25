#!/usr/bin/python3
"""每日一次，机器证书换短期 token；使用现有串行 Ansible 收敛，不常驻 agent。"""
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

ROOT = Path('/opt/homelab-etcd-controller')


def main():
    with open('/var/lib/homelab-etcd-controller/renew.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        login = subprocess.run(
            ['sudo', '-n', '/usr/bin/python3', str(ROOT / 'login.py')],
            capture_output=True, text=True, timeout=40,
        )
        if login.returncode or not login.stdout.strip():
            print('Bao 机器证书登录失败；保留现有证书与运行中的 etcd。', file=sys.stderr)
            return 1
        token = login.stdout.strip()
        env = dict(os.environ, BAO_TOKEN=token)
        try:
            for play in ['verify.yml', 'site.yml']:
                result = subprocess.run(
                    ['/home/panxiao81/.local/bin/ansible-playbook', play],
                    cwd=ROOT / 'ansible', env=env, timeout=750,
                )
                if result.returncode:
                    return result.returncode
            Path('/var/lib/homelab-etcd-controller/last-success').touch()
            return 0
        finally:
            request = urllib.request.Request(
                'https://bao.ad.ddupan.top:8200/v1/auth/token/revoke-self',
                data=b'{}', headers={'X-Vault-Token': token}, method='POST',
            )
            try:
                with urllib.request.urlopen(request, timeout=15):
                    pass
            except Exception:
                print('短期 token 撤销未确认，将由 TTL 自动失效。', file=sys.stderr)


if __name__ == '__main__':
    raise SystemExit(main())
