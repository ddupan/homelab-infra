#!/usr/bin/env python3
"""显式演练新 PG：停止 laptop 主库服务，验证代理自动切换，再回切。需 --run。"""
import importlib.util
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('pg_runner', ROOT / 'run.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def command(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, timeout=35, **kw)


def wait_until(fn, description, timeout=100):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if fn():
                print(description, flush=True)
                return
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
        time.sleep(2)
    raise RuntimeError(description + ' timeout')


def role(ip):
    with urllib.request.urlopen('http://' + ip + ':8008/patroni', timeout=3) as r:
        return json.load(r)['role']


def main():
    if sys.argv[1:] != ['--run']:
        raise SystemExit('需显式 --run；会停止生产 laptop PG 服务并在验收后回切。')
    address = 'https://bao.ad.ddupan.top:8200'
    token = runner.spiffe_token(address)
    database = 'homelab_ha_probe_' + str(int(time.time()))
    try:
        request = urllib.request.Request(address + '/v1/kv/data/infra/postgresql/ayatori/prod',
                                         headers={'X-Vault-Token': token})
        with urllib.request.urlopen(request, timeout=10) as r:
            credentials = json.load(r)['data']['data']
        env = dict(os.environ, PGHOST='pg-prod.ad.ddupan.top', PGHOSTADDR='192.168.10.2',
                   PGPORT='5432', PGDATABASE='postgres', PGUSER=credentials['username'],
                   PGPASSWORD=credentials['password'], PGSSLMODE='verify-full',
                   PGSSLROOTCERT=str(ROOT / 'ca.crt'), PGCONNECT_TIMEOUT='3')

        def sql(query, db='postgres'):
            result = command(['/usr/lib/postgresql/18/bin/psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
                             input=query, env=dict(env, PGDATABASE=db))
            if result.returncode:
                raise RuntimeError('SQL 验证失败: ' + result.stderr)
            return result.stdout.strip()

        def via(ip):
            try:
                return sql("SELECT host(inet_server_addr()) || ':' || "
                           "(NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off')::text") == ip + ':true'
            except RuntimeError:
                return False

        def rows(ip, count):
            args = ['sudo', '-n', '-u', 'pgprod', '/usr/lib/postgresql/18/bin/psql', '-X', '-At',
                    '-h', '/run/homelab-postgresql-prod', '-d', database, '-c', 'SELECT count(*) FROM probe']
            if ip != '192.168.10.127':
                args = ['ssh', 'root@' + ip, shlex.join(args)]
            return command(args).stdout.strip() == str(count)

        assert role('192.168.10.127') in ('master', 'primary')
        assert role('10.60.0.20') == 'replica'
        assert via('192.168.10.127')
        sql('CREATE DATABASE ' + database)
        print('探针数据库:', database, flush=True)
        sql('CREATE TABLE probe(id integer PRIMARY KEY); INSERT INTO probe VALUES(1)', database)
        wait_until(lambda: rows('10.60.0.20', 1), '初始数据已复制')
        started = time.monotonic()
        result = command(['sudo', '-n', 'systemctl', 'stop', 'homelab-postgresql-prod'])
        if result.returncode:
            raise RuntimeError('停止主库服务失败')
        wait_until(lambda: via('10.60.0.20'), '代理已自动切到 standby')
        sql('INSERT INTO probe VALUES(2)', database)
        print('自动恢复写入秒数:', round(time.monotonic() - started, 1), flush=True)
        command(['sudo', '-n', 'systemctl', 'start', 'homelab-postgresql-prod'], check=True)
        wait_until(lambda: role('192.168.10.127') == 'replica' and rows('192.168.10.127', 2),
                   '旧主重新作为 replica 加入，数据一致')
        result = command(['sudo', '-n', '-u', 'pgprod', '/opt/homelab-patroni/bin/patronictl',
                          '-c', '/etc/homelab-postgresql/prod/patroni.yml', 'switchover',
                          '--leader', 'pg-pve1', '--candidate', 'pg-laptop', '--force'])
        if result.returncode:
            raise RuntimeError('计划回切失败: ' + result.stderr)
        wait_until(lambda: via('192.168.10.127'), '已计划回切 laptop')
        sql('INSERT INTO probe VALUES(3)', database)
        wait_until(lambda: role('10.60.0.20') == 'replica' and rows('10.60.0.20', 3), '回切后复制正常')
        sql('DROP DATABASE ' + database)
        print('PASS；专属探针数据库已删除', flush=True)
    finally:
        # 即使演练失败，也确保原主服务重新运行；Patroni 自行决定角色，不强行提升。
        command(['sudo', '-n', 'systemctl', 'start', 'homelab-postgresql-prod'])
        runner.bao_request(address, 'auth/token/revoke-self', {}, token)


if __name__ == '__main__':
    main()
