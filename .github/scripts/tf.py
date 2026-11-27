#!/usr/bin/env python3
"""CI 用 Terraform 包装：凭据只在内存中传给 terraform 子进程，不写 GITHUB_ENV。

  tf.py run <root> <terraform args...>   取 state 与 root 凭据后执行 terraform
  tf.py comment <markdown-file> [marker]  在当前 PR 上新建或更新唯一一条带 marker 的评论
                                         （默认 terraform plan；chef.yml、flux-diff.yml 用自己的 marker）

依赖 spiffe-openbao-login 写入的 BAO_ADDR/BAO_TOKEN（role ci-terraform）。
JWT-SVID（GCP、OCI、iam-login）：有 SPIRE Workload API socket 时用 spire-agent（本机、Gitea executor），
否则经 spire-identity-exchange 换：homelab ARC runner 上交 runner Pod 的 PSAT + job 的 GitHub OIDC token
（stack arc），GitHub 托管 runner 经 tailnet 只交 GitHub OIDC token（stack hosted）。job 需要
permissions: id-token: write。与 ddupan/ci-actions lib/svid.js 同一协议。
"""
import base64
import hashlib
import http.client
import json
import os
import ssl
import tempfile
import time
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

MARKER = '<!-- terraform-plan -->'
# 评论有长度上限（GitHub 65536）；大 plan（openbao root）截断，完整输出看 job 日志。
MAX_COMMENT = 60000

# spire-identity-exchange（homelab-infra platform/sandbox-identity-exchange）。它用自己的 X509-SVID 提供
# HTTPS，只有 URI SAN：按 SPIFFE ID 校验对端，信任锚取自 WebPKI 的 SPIFFE bundle endpoint。
EXCHANGE_ARC = ('spire-identity-exchange.spire-identity-exchange.svc', 443, '/api/v1/svid/arc/jwt?format=token')
# Ayatori LB → sandbox NodePort（homelab-infra clusters/ayatori-prod/sandbox-k8s.yaml）。
EXCHANGE_HOSTED = ('sandbox-k8s.lab.ddupan.top', 8544, '/api/v1/svid/hosted/jwt?format=token')
EXCHANGE_ID = 'spiffe://ddupan.top/sandbox/spire-identity-exchange'
BUNDLE_URL = 'https://spire-bundle.lab.ddupan.top/'
PSAT_PATH = '/var/run/secrets/spire-identity-exchange/token'


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


def spire_jwt(env, audience):
    socket = env.get('SPIRE_AGENT_SOCKET', '/run/spire/agent-sockets/spire-agent.sock')
    if os.path.exists(socket):
        return json.loads(subprocess.run(
            ['spire-agent', 'api', 'fetch', 'jwt', '-audience', audience, '-socketPath', socket, '-output', 'json'],
            check=True, capture_output=True).stdout)[0]['svids'][0]['svid']
    return exchange_jwt(audience)


def exchange_jwt(audience):
    """A JWT-SVID from spire-identity-exchange (ARC runner or GitHub-hosted runner on the tailnet)."""
    if not os.environ.get('ACTIONS_ID_TOKEN_REQUEST_URL'):
        raise SystemExit('没有 SPIRE socket，也没有 GitHub OIDC token：job 需要 permissions: id-token: write')
    with urllib.request.urlopen(BUNDLE_URL, timeout=30) as response:
        keys = json.load(response)['keys']
    pems = [f"-----BEGIN CERTIFICATE-----\n{k['x5c'][0]}\n-----END CERTIFICATE-----\n"
            for k in keys if k.get('use') == 'x509-svid' and k.get('x5c')]
    context = ssl.create_default_context(cadata=''.join(pems))
    context.check_hostname = False  # identity is the SPIFFE ID below, not a DNS name
    # projected token 只存在于 ARC runner Pod；没有它就是托管 runner，走 hosted stack。
    psat = Path(PSAT_PATH).read_text().strip() if Path(PSAT_PATH).exists() else None
    host, port, path = EXCHANGE_ARC if psat else EXCHANGE_HOSTED
    last = None
    # Each GitHub OIDC token is single-use at the exchange (replay cache): a fresh one per attempt.
    for attempt in range(3):
        oidc = request(os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=spire-identity-exchange',
                       headers={'Authorization': f"Bearer {os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']}"})['value']
        try:
            conn = http.client.HTTPSConnection(host, port, context=context, timeout=30)
            conn.connect()
            sans = [v for k, v in conn.sock.getpeercert().get('subjectAltName', ()) if k == 'URI']
            if EXCHANGE_ID not in sans:
                raise SystemExit(f'exchange 的身份是 {sans}，不是 {EXCHANGE_ID}')
            # 单插件 stack 的 token 不带插件名前缀。
            auth = f'k8s={psat}:github-actions={oidc}' if psat else oidc
            conn.request('POST', path, json.dumps({'audiences': [audience]}),
                         {'Authorization': f'Bearer {auth}',
                          'Content-Type': 'application/json'})
            response = conn.getresponse()
            body = response.read().decode()
            if response.status == 200 and body.strip():
                return body.strip()
            last = f'HTTP {response.status} {body[:300]}'
            if response.status < 500:
                break  # wrong job or identity: retrying cannot help
        except OSError as e:
            last = str(e)
        time.sleep(5 * (attempt + 1))
    raise SystemExit(f'spire-identity-exchange 拒绝（aud {audience}）：{last}')


def run_gcp(root, args, env):
    """用 SPIRE JWT-SVID 经 Workload Identity Federation 以 terraform-ci 运行（gcp-ci/terraform/federation.tf）。"""
    shm = '/dev/shm' if os.path.isdir('/dev/shm') else None
    with tempfile.TemporaryDirectory(dir=shm) as directory:
        Path(f'{directory}/jwt').write_text(spire_jwt(env, 'gcp'))
        Path(f'{directory}/credentials.json').write_text(json.dumps({
            'type': 'external_account',
            'audience': '//iam.googleapis.com/projects/811223086070/locations/global'
                        '/workloadIdentityPools/spire/providers/spire',
            'subject_token_type': 'urn:ietf:params:oauth:token-type:jwt',
            'token_url': 'https://sts.googleapis.com/v1/token',
            'credential_source': {'file': f'{directory}/jwt', 'format': {'type': 'text'}},
            'service_account_impersonation_url': 'https://iamcredentials.googleapis.com/v1/projects/-'
                                                 '/serviceAccounts/terraform-ci@ddupan-ci.iam.gserviceaccount.com'
                                                 ':generateAccessToken',
        }))
        env['GOOGLE_APPLICATION_CREDENTIALS'] = f'{directory}/credentials.json'
        return subprocess.run(['terraform', f'-chdir={root}', *args], env=env).returncode


def run_oci(root, args, env):
    """用 SPIRE JWT-SVID 换 OCI UPST 后执行 terraform（infrastructure/oci/terraform/spire-federation.tf）。

    私钥和 token 只放在 tmpfs，terraform 结束即删。OCI 只从 $HOME/.oci/config 读配置，
    所以给子进程换 HOME，不碰真实的 ~/.oci/config（本地运行时它是 API key）。
    """
    client = bao_kv('infra/oci-token-exchange')
    if not client:
        raise SystemExit('kv/infra/oci-token-exchange 不存在：先按 infrastructure/oci/README.md 写入。')
    # aud 必须是 oci：trust 用 client_claim 绑定了它。
    svid = spire_jwt(env, 'oci')

    shm = '/dev/shm' if os.path.isdir('/dev/shm') else None
    with tempfile.TemporaryDirectory(dir=shm) as home:
        key = f'{home}/key.pem'
        subprocess.run(['openssl', 'genrsa', '-out', key, '2048'], check=True, capture_output=True)
        der = subprocess.run(['openssl', 'rsa', '-in', key, '-pubout', '-outform', 'DER'],
                             check=True, capture_output=True).stdout
        form = urllib.parse.urlencode({
            'grant_type': 'urn:ietf:params:oauth:grant-type:token-exchange',
            'requested_token_type': 'urn:oci:token-type:oci-upst',
            'public_key': base64.b64encode(der).decode(),
            'subject_token': svid,
            'subject_token_type': 'jwt',
        }).encode()
        basic = base64.b64encode(f"{client['client_id']}:{client['client_secret']}".encode()).decode()
        req = urllib.request.Request(
            'https://idcs-15519d43fa4e4b2588e6c0ffa5be9423.identity.oraclecloud.com/oauth2/v1/token', form,
            {'Authorization': f'Basic {basic}', 'Content-Type': 'application/x-www-form-urlencoded'})
        # WAN 随机断（CLAUDE.md）：连不上或超时就重试；sandbox 的 pod runner 上 2026-11-13 连续
        # 三次 apply 在这里超时，后面的 root 全部没跑到。
        for attempt in range(1, 4):
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    token = json.load(response)['token']
                break
            except urllib.error.HTTPError as e:
                # aud 或 subject 不匹配时 OCI 返回 500，不是 4xx，不要当作临时错误重试。
                raise SystemExit(f'换 OCI token 失败：HTTP {e.code} {e.read().decode()[:200]}') from None
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt == 3:
                    raise SystemExit(f'换 OCI token 失败：{e}') from None
                print(f'换 OCI token 第 {attempt} 次失败（{e}），10 秒后重试', file=sys.stderr)
                time.sleep(10)

        Path(f'{home}/token').write_text(token)
        fingerprint = hashlib.md5(der).hexdigest()
        fingerprint = ':'.join(fingerprint[i:i + 2] for i in range(0, len(fingerprint), 2))
        os.makedirs(f'{home}/.oci', mode=0o700)
        Path(f'{home}/.oci/config').write_text(
            f'[DEFAULT]\ntenancy=ocid1.tenancy.oc1..aaaaaaaalncmdinfnljot5oh7rqleavphhsa6jpyurfu4luztcct3tp5gsfa\n'
            f'region=ap-osaka-1\nfingerprint={fingerprint}\nkey_file={key}\nsecurity_token_file={home}/token\n')

        terraformrc = Path.home() / '.terraformrc'
        if terraformrc.exists():
            env.setdefault('TF_CLI_CONFIG_FILE', str(terraformrc))
        env['HOME'] = env['TF_HOME_OVERRIDE'] = home
        env['TF_VAR_oci_auth'] = 'SecurityToken'
        if args[0] == 'init':
            args = [*args, '-backend-config=auth=SecurityToken']
        return subprocess.run(['terraform', f'-chdir={root}', *args], env=env).returncode


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

    if name == 'oci':
        return run_oci(root, args, env)
    if name == 'gcp-ci':
        return run_gcp(root, args, env)

    # terraform-provider-homelab 平时每次请求从 Workload API 取 SVID；没有 socket 时（GitHub）给它一个现取的
    # （有效期 5 分钟，覆盖一个 root 的 plan/apply）。
    socket = env.get('SPIRE_AGENT_SOCKET', '/run/spire/agent-sockets/spire-agent.sock')
    if name == 'iam-login' and not os.path.exists(socket):
        env['HOMELAB_JWT_SVID_IAM_LOGIN'] = exchange_jwt('iam-login')

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
        body = body[:MAX_COMMENT] + '\n```\n\n…已截断，完整输出见 job 日志。'
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    api = f"{os.environ['GITHUB_API_URL']}/repos/{os.environ['GITHUB_REPOSITORY']}"
    auth = {'Authorization': f"Bearer {os.environ['GITHUB_TOKEN']}", 'Accept': 'application/vnd.github+json'}
    issue = f"{api}/issues/{event['pull_request']['number']}/comments"
    # ponytail: 只看第一页评论（100 条），评论更多的 PR 会新建而非更新
    mine = [c for c in request(issue + '?per_page=100', headers=auth) if c['body'].startswith(marker)]
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
