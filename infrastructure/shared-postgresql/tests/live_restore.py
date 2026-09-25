#!/usr/bin/env python3
"""将真实 pgBackRest 备份恢复到临时目录，仅用私有 Unix socket 启动并验证。"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def run(args, **kwargs):
    return subprocess.run(['sudo', '-n', '-u', 'pgprod', *args],
                          check=True, capture_output=True, text=True, timeout=240, **kwargs)


def main():
    if sys.argv[1:] != ['--run']:
        raise SystemExit('需显式 --run；仅恢复到新的临时目录，不接触原 PGDATA。')
    root = Path(tempfile.mkdtemp(prefix='homelab-pg-restore-', dir='/tmp'))
    data = root / 'data'
    started = False
    try:
        (root / 'pg_hba.conf').write_text('local all pgprod peer\n')
        (root / 'test.conf').write_text(
            f"data_directory='{data}'\nhba_file='{root}/pg_hba.conf'\n"
            f"unix_socket_directories='{root}'\nunix_socket_permissions=0700\n"
            "listen_addresses=''\nport=55432\nssl=off\narchive_mode=off\n"
            "shared_buffers=32MB\nmax_connections=80\nmax_wal_senders=5\n"
            "hot_standby=on\nprimary_conninfo=''\n")
        subprocess.run(['sudo', '-n', 'chown', '-R', 'pgprod:pgprod', str(root)], check=True)
        run(['pgbackrest', '--config=/etc/homelab-postgresql/prod/pgbackrest.conf', '--stanza=prod',
             '--pg1-path=' + str(data), '--type=immediate', '--target-action=promote',
             '--archive-mode=off', 'restore'])
        print('真实仓库备份已恢复到临时目录', flush=True)
        run(['/usr/lib/postgresql/18/bin/pg_ctl', '-D', str(data), '-l', str(root / 'server.log'),
             '-o', '-c config_file=' + str(root / 'test.conf'), '-w', '-t', '60', 'start'])
        started = True
        # pg_ctl ready 可早于 WAL recovery 完成；等待恢复结束并可写。
        for _ in range(60):
            result = run(['/usr/lib/postgresql/18/bin/psql', '-X', '-At', '-h', str(root), '-p', '55432',
                          '-d', 'postgres', '-c',
                          "SELECT NOT pg_is_in_recovery() AND NOT rolsuper AND rolcreatedb AND rolcreaterole "
                          "FROM pg_roles WHERE rolname='ayatori'"])
            if result.stdout.strip() == 't':
                break
            time.sleep(1)
        else:
            raise RuntimeError('恢复后 SQL/管理角色验证未通过')
        print('PASS：恢复实例可写、Ayatori 管理角色属性正确；仅私有 Unix socket', flush=True)
    except subprocess.CalledProcessError as e:
        print(e.stderr, file=sys.stderr)
        raise
    finally:
        # pg_ctl start 超时也可能已经创建 postmaster，清理前必须先确认停止。
        if started or (data / 'postmaster.pid').exists():
            run(['/usr/lib/postgresql/18/bin/pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop'])
        subprocess.run(['sudo', '-n', 'chown', '-R', str(os.getuid()) + ':' + str(os.getgid()), str(root)], check=True)
        shutil.rmtree(root)


if __name__ == '__main__':
    main()
