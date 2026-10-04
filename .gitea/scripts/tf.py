#!/usr/bin/env python3
"""CI 用 Terraform 包装：凭据只在内存中传给 terraform 子进程，不写 GITHUB_ENV。

  tf.py run <root> <terraform args...>   取 state 与 root 凭据后执行 terraform
  tf.py comment <markdown-file>         在当前 PR 上新建或更新唯一一条 plan 评论

依赖 spiffe-openbao-login 写入的 BAO_ADDR/BAO_TOKEN（role ci-terraform）。
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request

MARKER = '<!-- terraform-plan -->'
# Gitea 评论有长度上限；大 plan（openbao root）截断，完整输出看 job 日志。
MAX_COMMENT = 60000


def request(url, method='GET', body=None, headers=None):
    req = urllib.request.Request(
        url, method=method, headers={'Content-Type': 'application/json', **(headers or {})},
        data=json.dumps(body).encode() if body is not None else None,
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response) if response.status != 204 else None


def bao_kv(path):
    try:
        return request(f"{os.environ['BAO_ADDR'].rstrip('/')}/v1/kv/data/{path}",
                       headers={'X-Vault-Token': os.environ['BAO_TOKEN']})['data']['data']
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise SystemExit(f'读取 kv/{path} 失败：HTTP {e.code}') from None


def run(root, args):
    env = dict(os.environ)
    # vault provider 读 VAULT_TOKEN；bao 系 root 由此获得 ci-terraform 身份。
    env['VAULT_ADDR'], env['VAULT_TOKEN'] = env['BAO_ADDR'], env['BAO_TOKEN']

    # 与 infrastructure/*/run.py 相同：tfstate 用 SeaweedFS 的 terraform 受限身份。
    config = bao_kv('k8s/seaweedfs-s3')['seaweedfs_s3_config']
    config = json.loads(config) if isinstance(config, str) else config
    ids = [i for i in config['identities'] if i['name'] == 'terraform']
    if len(ids) != 1 or len(ids[0]['credentials']) != 1:
        raise SystemExit('tfstate 身份不唯一，拒绝猜测凭据。')
    env['AWS_ACCESS_KEY_ID'] = ids[0]['credentials'][0]['accessKey']
    env['AWS_SECRET_ACCESS_KEY'] = ids[0]['credentials'][0]['secretKey']

    # root 自身变量（API token 等，本地放在 gitignored tfvars）：
    # kv/infra/terraform/<root 名> 的每个 key 原样作为 TF_VAR_<key>。bao 系 root 没有这项。
    name = Path(root).parent.name
    for key, value in (bao_kv(f'infra/terraform/{name}') or {}).items():
        env[f'TF_VAR_{key}'] = value

    return subprocess.run(['terraform', f'-chdir={root}', *args], env=env).returncode


def comment(markdown_file):
    body = MARKER + '\n' + Path(markdown_file).read_text()
    if len(body) > MAX_COMMENT:
        body = body[:MAX_COMMENT] + '\n```\n\n…已截断，完整 plan 见 job 日志。'
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    api = f"{os.environ['GITHUB_SERVER_URL']}/api/v1/repos/{os.environ['GITHUB_REPOSITORY']}"
    auth = {'Authorization': f"token {os.environ['GITEA_TOKEN']}"}
    issue = f"{api}/issues/{event['pull_request']['number']}/comments"
    # ponytail: 只看第一页评论（默认 50 条），评论更多的 PR 会新建而非更新
    mine = [c for c in request(issue, headers=auth) if c['body'].startswith(MARKER)]
    if mine:
        request(f"{api}/issues/comments/{mine[0]['id']}", 'PATCH', {'body': body}, auth)
    else:
        request(issue, 'POST', {'body': body}, auth)


if __name__ == '__main__':
    if sys.argv[1:2] == ['run'] and len(sys.argv) > 3:
        raise SystemExit(run(sys.argv[2], sys.argv[3:]))
    if sys.argv[1:2] == ['comment'] and len(sys.argv) == 3:
        raise SystemExit(comment(sys.argv[2]))
    raise SystemExit(__doc__)
