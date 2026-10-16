#!/usr/bin/env python3
"""把 config.json 里的 CI OIDC provider 与 mapping 对齐到 Artifact Keeper。

这些对象只能经 AK 的 admin API 配置，没有 Terraform provider，所以由本脚本按名字增改。
不删除：config.json 里没有的 provider/mapping 只列出来，删不删由人决定。
admin token 取自 Bao kv/infra/artifact-keeper 的 api_token（需先 bao login，或设 AK_TOKEN）。

  python3 apply.py --check   # 只列出将要做的变更
  python3 apply.py           # 应用；再跑一次应没有任何输出
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent
AK = os.environ.get('AK_URL', 'https://artifacts.lab.ddupan.top').rstrip('/') + '/api/v1/admin/ci-oidc'


def token():
    if os.environ.get('AK_TOKEN'):
        return os.environ['AK_TOKEN']
    env = dict(os.environ)
    env.setdefault('BAO_ADDR', 'https://bao.lab.ddupan.top:8200')
    return subprocess.run(['bao', 'kv', 'get', '-field=api_token', 'kv/infra/artifact-keeper'],
                          env=env, check=True, capture_output=True, text=True).stdout.strip()


def call(auth, method, path, body=None):
    req = urllib.request.Request(AK + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={'Authorization': f'Bearer {auth}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        raise SystemExit(f'{method} {path}: {e.code} {e.read().decode(errors="replace")[:500]}')


def diff(want, have):
    # issuer_url 末尾的 / 在 AK 里不算差别。
    norm = lambda k, v: v.rstrip('/') if k == 'issuer_url' and isinstance(v, str) else v
    return {k: v for k, v in want.items() if norm(k, v) != norm(k, have.get(k))}


def sync(auth, check, kind, path, wanted, existing):
    """按 name 增改一组对象，返回 {name: 现有或新建对象}。"""
    by_name = {o['name']: o for o in existing}
    for name in sorted(set(by_name) - {w['name'] for w in wanted}):
        print(f'  未托管的 {kind}：{name}（保留）')
    out = {}
    for want in wanted:
        have = by_name.get(want['name'])
        if have is None:
            print(f'+ {kind} {want["name"]}')
            out[want['name']] = None if check else call(auth, 'POST', path, want)
            continue
        changes = diff(want, have)
        if changes:
            print(f'~ {kind} {want["name"]}: {", ".join(sorted(changes))}')
            if not check:
                have = call(auth, 'PUT', f'{path}/{have["id"]}', changes)
        out[want['name']] = have
    return out


def main():
    check = '--check' in sys.argv[1:]
    config = json.loads((ROOT / 'config.json').read_text())
    auth = token()
    providers = [{k: v for k, v in p.items() if k != 'mappings'} for p in config['providers']]
    synced = sync(auth, check, 'provider', '', providers, call(auth, 'GET', ''))
    for p in config['providers']:
        provider = synced[p['name']]
        mappings = [] if provider is None else call(auth, 'GET', f'/{provider["id"]}/mappings')
        if provider is None:
            # --check 下新 provider 尚未创建，其 mapping 都是新增。
            for m in p.get('mappings', []):
                print(f'+ mapping {p["name"]}/{m["name"]}')
            continue
        sync(auth, check, f'mapping {p["name"]}', f'/{provider["id"]}/mappings', p.get('mappings', []), mappings)


if __name__ == '__main__':
    main()
