#!/usr/bin/env python3
"""CI 用 Terraform 包装：凭据只在内存中传给 terraform 子进程，不写 GITHUB_ENV。

  tf.py run <root> <terraform args...>   取 state 与 root 凭据后执行 terraform
  tf.py comment <markdown-file> [marker]  在当前 PR 上新建或更新唯一一条带 marker 的评论
                                         （默认 terraform plan；chef.yml 用自己的 marker）

依赖 spiffe-openbao-login 写入的 BAO_ADDR/BAO_TOKEN（role ci-terraform）。
"""
import json
import os
import tempfile
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

    # PowerDNS API key 只有一份，在 kv/k8s/powerdns（ESO 只能读 k8s/，Poweradmin 与
    # external-dns 也用它），所以不按上面的约定复制到 kv/infra/terraform/<root>。
    # dns 管 zone，incus 注册自己实例的记录。
    if name in ('dns', 'incus'):
        env['PDNS_API_KEY'] = bao_kv('k8s/powerdns')['api_key']

    # svc-nexus 的密码由 samba-ad play 生成，只存一份在 kv/infra/nexus-ldap
    # （play 整份覆盖写该路径，不能与 kv/infra/terraform/nexus 共用）。
    if name == 'nexus':
        bind = bao_kv('infra/nexus-ldap')
        if not bind:
            raise SystemExit('kv/infra/nexus-ldap 不存在：先运行 samba-ad provision-dc.yml --tags accounts。')
        env['TF_VAR_ldap_bind_username'] = bind['username']
        env['TF_VAR_ldap_bind_password'] = bind['password']

    if name != 'incus':
        return subprocess.run(['terraform', f'-chdir={root}', *args], env=env).returncode

    # incus：Incus 信任 Bao pki-incus 签发、未过期的客户端证书（core.trust_ca_certificates）。
    # 每次调用现签 30 分钟证书，用完即弃；provider 只从 config_dir 读证书，私钥只能落盘，
    # 故放在 tmpfs 的 0700 临时目录，terraform 结束即删。
    issued = request(f"{env['BAO_ADDR'].rstrip('/')}/v1/pki-incus/issue/ci-terraform", 'POST',
                     {'common_name': 'ci-terraform'}, {'X-Vault-Token': env['BAO_TOKEN']})['data']
    shm = '/dev/shm' if os.path.isdir('/dev/shm') else None
    with tempfile.TemporaryDirectory(dir=shm) as config_dir:
        os.makedirs(f'{config_dir}/servercerts')
        Path(f'{config_dir}/servercerts/local.crt').write_text(Path(root, 'server.crt').read_text())
        Path(f'{config_dir}/client.crt').write_text(issued['certificate'] + '\n')
        key = os.open(f'{config_dir}/client.key', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(key, 'w') as f:
            f.write(issued['private_key'] + '\n')
        env['TF_VAR_incus_address'] = 'https://192.168.10.127:8443'
        env['TF_VAR_incus_config_dir'] = config_dir
        # 同一镜像并行建多个实例会撞上 Incus simplestreams 缓存的 mkdir 竞争（见 incus README）。
        env['TF_CLI_ARGS_apply'] = '-parallelism=1'
        return subprocess.run(['terraform', f'-chdir={root}', *args], env=env).returncode


def comment(markdown_file, marker=MARKER):
    body = marker + '\n' + Path(markdown_file).read_text()
    if len(body) > MAX_COMMENT:
        body = body[:MAX_COMMENT] + '\n```\n\n…已截断，完整 plan 见 job 日志。'
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    api = f"{os.environ['GITHUB_SERVER_URL']}/api/v1/repos/{os.environ['GITHUB_REPOSITORY']}"
    auth = {'Authorization': f"token {os.environ['GITEA_TOKEN']}"}
    issue = f"{api}/issues/{event['pull_request']['number']}/comments"
    # ponytail: 只看第一页评论（默认 50 条），评论更多的 PR 会新建而非更新
    mine = [c for c in request(issue, headers=auth) if c['body'].startswith(marker)]
    if mine:
        request(f"{api}/issues/comments/{mine[0]['id']}", 'PATCH', {'body': body}, auth)
    else:
        request(issue, 'POST', {'body': body}, auth)


if __name__ == '__main__':
    if sys.argv[1:2] == ['run'] and len(sys.argv) > 3:
        raise SystemExit(run(sys.argv[2], sys.argv[3:]))
    if sys.argv[1:2] == ['comment'] and len(sys.argv) in (3, 4):
        raise SystemExit(comment(*sys.argv[2:]))
    raise SystemExit(__doc__)
