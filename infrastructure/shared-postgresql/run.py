#!/usr/bin/env python3
"""从显式登录会话或本机 SPIFFE 获取 Bao 凭据，仅传入子进程内存。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parent


def bao_request(address, path, body, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['X-Vault-Token'] = token
    request = urllib.request.Request(
        address.rstrip('/') + '/v1/' + path,
        data=json.dumps(body).encode(), headers=headers,
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response) if response.status != 204 else None


def spiffe_token(address):
    response = subprocess.run(
        ['spire-agent', 'api', 'fetch', 'jwt', '-audience', 'openbao',
         '-socketPath', '/run/spire/agent-sockets/spire-agent.sock', '-output', 'json'],
        capture_output=True, text=True,
    )
    if response.returncode:
        raise SystemExit('本机 SPIFFE 身份获取失败；未回退到其他身份。')
    try:
        jwt = json.loads(response.stdout)[0]['svids'][0]['svid']
        return bao_request(address, 'auth/jwt-spire/login',
                           {'role': os.environ.get('PG_BAO_SPIFFE_ROLE', 'local-development'), 'jwt': jwt})['auth']['client_token']
    except (ValueError, KeyError, IndexError, urllib.error.URLError):
        raise SystemExit('本机 SPIFFE 登录 Bao 失败；未输出秘密。') from None


def main():
    args = sys.argv[1:]
    use_spiffe = bool(args and args[0] == '--spiffe')
    if use_spiffe:
        args.pop(0)
    if len(args) < 2 or args[0] not in ('terraform', 'ansible'):
        raise SystemExit('用法：python3 run.py [--spiffe] terraform <args> | ansible <playbook> [args]')
    env = dict(os.environ)
    env.setdefault('BAO_ADDR', 'https://bao.ad.ddupan.top:8200')
    token = spiffe_token(env['BAO_ADDR']) if use_spiffe else (
        env.get('BAO_TOKEN') or env.get('VAULT_TOKEN')
        or Path('~/.vault-token').expanduser().read_text().strip())
    try:
        return run_command(args, env, token)
    finally:
        if use_spiffe:
            try:
                bao_request(env['BAO_ADDR'], 'auth/token/revoke-self', {}, token)
            except urllib.error.URLError:
                print('短期会话撤销失败，将按服务器 TTL 到期。', file=sys.stderr)


def run_command(args, env, token):
    env['BAO_TOKEN'] = env['VAULT_TOKEN'] = token
    if args[0] == 'terraform':
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
        command, cwd = ['terraform', *args[1:]], ROOT / 'terraform'
    else:
        command, cwd = ['ansible-playbook', *args[1:]], ROOT / 'ansible'
    return subprocess.run(command, cwd=cwd, env=env).returncode


if __name__ == '__main__':
    raise SystemExit(main())
