#!/usr/bin/env python3
"""临时三成员 mTLS/RBAC 集成测试；仅绑定 loopback，不访问生产 Bao。"""
import base64
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('ETCD_TEST_BIN', '/tmp/etcd-v3.7.2-linux-amd64'))


def run(argv, **kwargs):
    return subprocess.run([str(x) for x in argv], capture_output=True, text=True, check=True, **kwargs)


class FakeBao(BaseHTTPRequestHandler):
    records = {}
    versions = {}
    writes = 0
    deny = False

    def log_message(self, *_):
        pass

    def respond(self, status, body):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        if self.deny:
            return self.respond(403, {'errors': ['permission denied']})
        name = self.path.rsplit('/', 1)[-1]
        if '/metadata/' in self.path and name in self.versions:
            return self.respond(200, {'data': {'current_version': self.versions[name]}})
        if '/data/' in self.path and name in self.records:
            return self.respond(200, {'data': {'data': self.records[name]}})
        self.respond(404, {'errors': []})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        name = self.path.rsplit('/', 1)[-1]
        if body['options']['cas'] != 0 or name in self.versions:
            return self.respond(400, {'errors': ['CAS mismatch']})
        self.records[name] = body['data']
        self.versions[name] = 1
        type(self).writes += 1
        self.respond(200, {'data': {'version': 1}})


def main():
    for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
        os.environ.pop(key, None)
    os.environ['NO_PROXY'] = '*'
    processes = []
    handles = []
    server = None
    with tempfile.TemporaryDirectory(prefix='shared-etcd-test-') as work:
        w = Path(work)
        w.chmod(0o700)
        try:
            run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', w/'ca.key',
                 '-out', w/'ca.crt', '-days', '1', '-subj', '/CN=isolated-test-ca'])

            def cert(name, cn, eku, ip=None):
                run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', w/f'{name}.key',
                     '-out', w/f'{name}.csr', '-subj', f'/CN={cn}' if cn else '/'])
                ext = w/f'{name}.ext'
                ext.write_text(f'extendedKeyUsage={eku}\n' + (f'subjectAltName=IP:{ip},IP:127.0.0.1\n' if ip else ''))
                run(['openssl', 'x509', '-req', '-in', w/f'{name}.csr', '-CA', w/'ca.crt',
                     '-CAkey', w/'ca.key', '-CAcreateserial', '-out', w/f'{name}.crt', '-days', '1', '-extfile', ext])

            cert('admin', 'root', 'clientAuth')
            cert('client', '', 'clientAuth')
            cert('gateway', '', 'clientAuth')
            env = jinja2.Environment(loader=jinja2.FileSystemLoader(ROOT/'ansible/roles/shared_etcd/templates'), undefined=jinja2.StrictUndefined)
            env.filters['to_json'] = json.dumps
            defaults = yaml.safe_load((ROOT/'ansible/roles/shared_etcd/defaults/main.yml').read_text())
            names = ['test1', 'test2', 'test3']
            hosts = {name: {'etcd_address': f'127.0.0.{i+2}'} for i, name in enumerate(names)}
            for name in names:
                d = w/name
                d.mkdir()
                for kind, cn, eku in [('server', name, 'serverAuth'), ('peer', 'homelab-etcd-peer', 'serverAuth,clientAuth')]:
                    cert(f'{name}-{kind}', cn, eku, hosts[name]['etcd_address'])
                    for suffix in ['crt', 'key']:
                        shutil.copy(w/f'{name}-{kind}.{suffix}', d/f'{kind}.{suffix}')
                shutil.copy(w/'ca.crt', d/'ca.crt')
                for suffix in ['crt', 'key']:
                    shutil.copy(w/f'gateway.{suffix}', d/f'gateway.{suffix}')
                values = dict(defaults, inventory_hostname=name, groups={'etcd': names}, hostvars=hosts,
                              etcd_address=hosts[name]['etcd_address'], etcd_config_dir=str(d), etcd_data_dir=str(d/'data'),
                              etcd_client_port=22379, etcd_peer_port=22380, etcd_metrics_port=0)
                config = env.get_template('etcd.yml.j2').render(**values)
                # 三成员共享进程命名空间，metrics 用独立 loopback IP。
                config = config.replace('http://127.0.0.1:0', f"http://{hosts[name]['etcd_address']}:22381")
                (d/'config.yml').write_text(config)
                handle = (d/'etcd.log').open('w')
                handles.append(handle)
                processes.append(subprocess.Popen([str(BIN/'etcd'), '--config-file='+str(d/'config.yml')], stdout=handle, stderr=handle))

            base_env = dict(os.environ, ETCDCTL_ENDPOINTS='https://127.0.0.2:22379', ETCDCTL_CACERT=str(w/'ca.crt'),
                            ETCDCTL_CERT=str(w/'admin.crt'), ETCDCTL_KEY=str(w/'admin.key'), ETCDCTL_DIAL_TIMEOUT='2s', ETCDCTL_COMMAND_TIMEOUT='3s')

            def ctl(*args, input=None, env=None):
                return run([BIN/'etcdctl', *args], input=input, env=env or base_env)

            for attempt in range(5):
                try:
                    ctl('endpoint', 'health')
                    break
                except subprocess.CalledProcessError:
                    if any(p.poll() is not None for p in processes):

                        for name in names:
                            print((w/name/'etcd.log').read_text()[-4000:])
                        raise RuntimeError('test etcd exited during startup')
                    time.sleep(0.2)
            else:

                print((w/'test1'/'etcd.log').read_text()[-5000:])
                raise RuntimeError('test quorum did not form')
            server = ThreadingHTTPServer(('127.0.0.1', 0), FakeBao)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            inventory = w/'hosts.yml'
            inventory.write_text(yaml.safe_dump({'all': {'children': {'etcd': {'hosts': {'test1': {'ansible_connection': 'local'}}}}}}))
            extra = {
                'ansible_become': False, 'etcd_address': '127.0.0.2', 'etcd_client_port': 22379,
                'etcd_install_dir': str(BIN), 'etcd_config_dir': str(w), 'etcd_bootstrap_auth': True,
                'etcd_bao_url': f'http://127.0.0.1:{server.server_port}', 'etcd_bao_token': 'isolated-test-token',
                'etcd_bao_kv_mount': 'kv', 'etcd_bao_secret_base': 'infra/etcd/consumers',
                'etcd_consumers': [{'name': 'patroni-pg-prod', 'prefix': '/homelab/patroni/pg-prod/'}],
            }
            (w/'extra.json').write_text(json.dumps(extra))
            ansible_env = dict(os.environ, ANSIBLE_LOCAL_TEMP=str(w/'ansible-tmp'), ANSIBLE_NOCOLOR='1',
                               ANSIBLE_ROLES_PATH=str(ROOT/'ansible/roles'))

            def play(name, fail=False):
                r = subprocess.run(['ansible-playbook', '-i', str(inventory), str(ROOT/'ansible'/name), '-e', '@'+str(w/'extra.json')],
                                   capture_output=True, text=True, env=ansible_env)
                (w/(name+'.log')).write_text(r.stdout+r.stderr)
                if fail:
                    assert r.returncode != 0, 'expected a fail-closed playbook error'
                elif r.returncode:
                    # Tasks use no_log for secret data; retain useful task/line diagnostic.
                    print(r.stdout[-5000:]);print(r.stderr[-2000:])
                    raise RuntimeError(name+' failed')
                return r.stdout

            play('bootstrap-auth.yml')
            assert re.search(r'changed=0\s', play('bootstrap-auth.yml'))
            play('consumers.yml')
            secret = FakeBao.records['patroni-pg-prod']['password']
            assert len(secret) == 48
            assert re.search(r'changed=0\s', play('consumers.yml'))
            assert FakeBao.writes == 1
            role = json.loads(ctl('--write-out=json', 'role', 'get', 'patroni-pg-prod').stdout)
            assert role['perm'][0]['key'] == base64.b64encode(b'/homelab/patroni/pg-prod/').decode()
            client_env = dict(base_env, ETCDCTL_CERT=str(w/'client.crt'), ETCDCTL_KEY=str(w/'client.key'),
                              ETCDCTL_USER='patroni-pg-prod', ETCDCTL_PASSWORD=secret)
            ctl('put', '/homelab/patroni/pg-prod/test', 'ok', env=client_env)
            try:
                ctl('put', '/homelab/other/test', 'denied', env=client_env)
                raise AssertionError('cross-prefix write succeeded')
            except subprocess.CalledProcessError:
                pass
            # 模拟 Patroni 的 gateway 协议，证明 mTLS + username/password 可组合使用。
            ctx = ssl.create_default_context(cafile=str(w/'ca.crt'))
            ctx.load_cert_chain(w/'client.crt', w/'client.key')
            body = json.dumps({'name':'patroni-pg-prod', 'password':secret}).encode()
            req = urllib.request.Request('https://127.0.0.2:22379/v3/auth/authenticate', data=body, headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req, context=ctx) as response:
                token = json.load(response)['token']
            gateway_body = json.dumps({'key': base64.b64encode(b'/homelab/patroni/pg-prod/gateway').decode(),
                                       'value': base64.b64encode(b'ok').decode()}).encode()
            req = urllib.request.Request('https://127.0.0.2:22379/v3/kv/put', data=gateway_body,
                                         headers={'Content-Type': 'application/json', 'Authorization': token})
            with urllib.request.urlopen(req, context=ctx) as response:
                assert response.status == 200
            # 对已有用户，秘密值被意外覆盖也必须失败，而不是悄悄改 etcd 密码。
            FakeBao.records['patroni-pg-prod']['password'] = 'x' * 48
            play('consumers.yml', fail=True)
            FakeBao.records['patroni-pg-prod']['password'] = secret
            FakeBao.deny = True
            play('consumers.yml', fail=True)
            FakeBao.deny = False
            saved = FakeBao.records.pop('patroni-pg-prod')
            play('consumers.yml', fail=True)  # metadata 存在、data 已删除
            FakeBao.versions.clear()
            play('consumers.yml', fail=True)  # 用户存在但 metadata 丢失
            assert FakeBao.writes == 1
            FakeBao.records['patroni-pg-prod'] = saved
            FakeBao.versions['patroni-pg-prod'] = 1
            ctl('snapshot', 'save', str(w/'snapshot.db'))
            snapshot = json.loads(run([BIN/'etcdutl', '--write-out=json', 'snapshot', 'status', w/'snapshot.db']).stdout)
            assert snapshot['totalKey'] > 0
            run([BIN/'etcdutl', 'snapshot', 'restore', w/'snapshot.db', '--data-dir='+str(w/'restored')])
            rss = []
            for process in processes:
                match = re.search(r'^VmRSS:\s+(\d+)', Path(f'/proc/{process.pid}/status').read_text(), re.M)
                rss.append(round(int(match[1]) / 1024, 1))
            processes[2].terminate();processes[2].wait(timeout=10)
            ctl('put', '/homelab/patroni/pg-prod/after-member-loss', 'ok', env=client_env)
            print('PASS: three-member mTLS, auth bootstrap/idempotence, Bao create-once/fail-closed, prefix isolation, gateway auth, snapshot/restore, one-member loss')
            print('Idle test member RSS MiB (not a production capacity result):', rss)
        finally:
            if server:
                server.shutdown();server.server_close()
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: process.kill();process.wait()
            for handle in handles:
                handle.close()


if __name__ == '__main__':
    main()
