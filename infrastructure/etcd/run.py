#!/usr/bin/env python3
"""从当前 Bao 登录会话向子进程传递凭据，不写临时秘密文件或输出秘密。"""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('terraform', 'ansible'):
        raise SystemExit('用法：python3 run.py terraform <args> | ansible <playbook> [args]')
    env = dict(os.environ)
    env.setdefault('BAO_ADDR', 'https://bao.lab.ddupan.top:8200')
    token = env.get('BAO_TOKEN') or env.get('VAULT_TOKEN')
    if not token:
        token = Path('~/.vault-token').expanduser().read_text().strip()
    env['BAO_TOKEN'] = env['VAULT_TOKEN'] = token
    if sys.argv[1] == 'terraform':
        response = subprocess.run(
            ['bao', 'kv', 'get', '-format=json', 'kv/k8s/seaweedfs-s3'],
            env=env, capture_output=True, text=True,
        )
        if response.returncode:
            raise SystemExit('读取 tfstate 受限身份失败；请检查 Bao 登录和授权。')
        config = json.loads(response.stdout)['data']['data']['seaweedfs_s3_config']
        config = json.loads(config) if isinstance(config, str) else config
        identities = [i for i in config['identities'] if i['name'] == 'terraform']
        if len(identities) != 1 or len(identities[0]['credentials']) != 1:
            raise SystemExit('tfstate 身份不唯一，拒绝猜测凭据。')
        credential = identities[0]['credentials'][0]
        env['AWS_ACCESS_KEY_ID'] = credential['accessKey']
        env['AWS_SECRET_ACCESS_KEY'] = credential['secretKey']
        command, cwd = ['terraform', *sys.argv[2:]], ROOT / 'terraform'
    else:
        command, cwd = ['ansible-playbook', *sys.argv[2:]], ROOT / 'ansible'
    raise SystemExit(subprocess.run(command, cwd=cwd, env=env).returncode)


if __name__ == '__main__':
    main()
