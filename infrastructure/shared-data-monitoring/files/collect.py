#!/usr/bin/env python3
"""只读检查共享数据服务，原子发布无秘密 textfile 指标。"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time


def command(argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=15).stdout.strip()


def certificate_expiry(path):
    # 检查完整 PEM 链；任何一张缺失/损坏都不能被当作健康。
    blocks = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                        Path(path).read_text(), re.S)
    if not blocks:
        raise ValueError('empty certificate chain')
    expiries = []
    for block in blocks:
        result = subprocess.run(['openssl', 'x509', '-noout', '-enddate'], input=block,
                                capture_output=True, text=True, check=True, timeout=5)
        date = result.stdout.strip().removeprefix('notAfter=')
        expiries.append(datetime.datetime.strptime(date, '%b %d %H:%M:%S %Y GMT')
                        .replace(tzinfo=datetime.timezone.utc).timestamp())
    return min(expiries)


def latest_backup(data):
    stanza = next(x for x in data if x['name'] == 'prod')
    if stanza['status']['code'] != 0:
        raise ValueError('repository status not ok')
    return max((b['timestamp']['stop'] for b in stanza['backup']
                if b['type'] == 'full' and b.get('error') is False), default=0)


def latest_snapshot(directory):
    return max((p.stat().st_mtime for p in Path(directory).iterdir()
                if re.fullmatch(r'\d{8}T\d{6}Z\.db', p.name) and p.is_file()), default=0)


def collect(config):
    lines = []

    def emit(name, value, **labels):
        suffix = '{' + ','.join(k + '=' + json.dumps(v) for k, v in sorted(labels.items())) + '}' if labels else ''
        lines.append(f'homelab_data_{name}{suffix} {float(value)}')

    def check(name, fn, **labels):
        try:
            value = fn()
        except (OSError, ValueError, KeyError, TypeError, StopIteration, subprocess.SubprocessError):
            # 不输出底层命令内容；某项失败不阻断其他检查，也不保留旧成功值。
            emit(name, 0, **labels)
            emit('check_success', 0, check=name, **labels)
        else:
            emit(name, value, **labels)
            emit('check_success', 1, check=name, **labels)

    for cert in config['certificates']:
        check('certificate_expiry_timestamp_seconds', lambda c=cert: certificate_expiry(c['path']),
              certificate=cert['name'])
    check('backup_timestamp_seconds', lambda: latest_snapshot(config['snapshot_dir']), backup='etcd')
    if config.get('repository'):
        check('backup_timestamp_seconds', lambda: latest_backup(json.loads(command([
            'runuser', '-u', 'pgbackup', '--', 'pgbackrest',
            '--config=/etc/homelab-pgbackrest/repository.conf', '--stanza=prod', '--output=json', 'info'
        ]))), backup='postgresql-prod')
    if config.get('dev'):
        def dev_health():
            result = command(['runuser', '-u', 'pgdev', '--', '/usr/lib/postgresql/18/bin/psql',
                              '-X', '-w', '-At', '-v', 'ON_ERROR_STOP=1',
                              '-h', '/run/homelab-postgresql-dev', '-p', '5433',
                              '-U', 'pgdev', '-d', 'postgres', '-c',
                              "SELECT (NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off')::int"])
            if result not in ('0', '1'):
                raise ValueError('unexpected SQL response')
            return int(result)
        check('dev_sql_ready', dev_health)
    for unit in config.get('renewal_units', []):
        def renewal(u=unit):
            props = dict(line.split('=', 1) for line in command([
                'systemctl', 'show', u + '.service', '-p', 'Result', '-p', 'ExecMainExitTimestamp',
                '-p', 'ExecMainStatus', '-p', 'LoadState']).splitlines())
            if props.get('LoadState') != 'loaded' or props.get('Result') != 'success' or props.get('ExecMainStatus') != '0':
                raise ValueError('renewal unsuccessful')
            timestamp = command(['date', '-d', props['ExecMainExitTimestamp'], '+%s'])
            if command(['systemctl', 'is-active', u + '.timer']) != 'active':
                raise ValueError('renewal timer inactive')
            return int(timestamp)
        check('renewal_success_timestamp_seconds', renewal, unit=unit)
    emit('collection_timestamp_seconds', time.time())
    return '\n'.join(lines) + '\n'


def publish(path, content):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    publish(args.output, collect(json.loads(Path(args.config).read_text())))


if __name__ == '__main__':
    main()
