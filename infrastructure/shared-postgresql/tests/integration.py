#!/usr/bin/env python3
"""真实 PG/Patroni/HAProxy/pgBackRest；仅 loopback、临时测试 CA/密码，不访问生产。"""
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import time
import urllib.request

import jinja2
import yaml

ROOT = Path(__file__).resolve().parents[1]
ETCD = Path(os.environ.get('ETCD_TEST_BIN', '/tmp/etcd-v3.7.2-linux-amd64'))
IMAGE = os.environ.get('PG_TEST_IMAGE', 'homelab-pg-test:18-patroni4.1.5')


def run(args, **kw):
    return subprocess.run([str(x) for x in args], capture_output=True, text=True, check=True, **kw)


def wait_for(check, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (subprocess.CalledProcessError, OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError('timed out waiting for fixture state')


def main():
    os.environ['NO_PROXY'] = '*'
    processes, handles, containers = [], [], []
    with tempfile.TemporaryDirectory(prefix='shared-pg-test-') as tmp:
        w = Path(tmp)
        pg = w/'pg'; pg.mkdir(); pg.chmod(0o755)
        prefix = f'shared-pg-test-{os.getpid()}'
        env = jinja2.Environment(loader=jinja2.FileSystemLoader(ROOT/'ansible/roles/pg_instance/templates'), undefined=jinja2.StrictUndefined)
        env.filters['to_json'] = json.dumps
        try:
            run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', w/'ca.key', '-out', w/'ca.crt', '-days', '1', '-subj', '/CN=pg-isolated-ca'])

            def cert(directory, name, cn, eku, sans=''):
                directory.mkdir(parents=True, exist_ok=True)
                run(['openssl','req','-new','-newkey','rsa:2048','-nodes','-keyout',directory/f'{name}.key','-out',directory/f'{name}.csr','-subj',f'/CN={cn}' if cn else '/'])
                ext = directory/f'{name}.ext'; ext.write_text(f'extendedKeyUsage={eku}\n'+(f'subjectAltName={sans}\n' if sans else ''))
                run(['openssl','x509','-req','-in',directory/f'{name}.csr','-CA',w/'ca.crt','-CAkey',w/'ca.key','-CAcreateserial','-out',directory/f'{name}.crt','-days','1','-extfile',ext])
                if directory != w:
                    shutil.copy(w/'ca.crt',directory/'ca.crt')

            # 独立三成员 DCS，绝不复用生产 prefix 或端点。
            names = ['e1','e2','e3']
            hosts = {n:{'etcd_address':f'127.0.1.{i+1}'} for i,n in enumerate(names)}
            et = jinja2.Environment(loader=jinja2.FileSystemLoader(ROOT.parent/'etcd/ansible/roles/shared_etcd/templates'),undefined=jinja2.StrictUndefined)
            et.filters['to_json']=json.dumps
            defaults=yaml.safe_load((ROOT.parent/'etcd/ansible/roles/shared_etcd/defaults/main.yml').read_text())
            cert(w,'admin','root','clientAuth')
            for name in names:
                d=w/name; ip=hosts[name]['etcd_address']
                cert(d,'server',name,'serverAuth',f'IP:{ip},IP:127.0.0.1')
                cert(d,'peer','homelab-etcd-peer','serverAuth,clientAuth',f'IP:{ip},IP:127.0.0.1')
                cert(d,'gateway','','clientAuth')
                cfg=et.get_template('etcd.yml.j2').render(**dict(defaults,inventory_hostname=name,groups={'etcd':names},hostvars=hosts,etcd_address=ip,etcd_config_dir=str(d),etcd_data_dir=str(d/'data'),etcd_client_port=23379,etcd_peer_port=23380,etcd_metrics_urls=f'http://{ip}:23381'))
                (d/'config.yml').write_text(cfg); log=(d/'log').open('w');handles.append(log)
                processes.append(subprocess.Popen([str(ETCD/'etcd'),'--config-file='+str(d/'config.yml')],stdout=log,stderr=log))
            ctlbase=[ETCD/'etcdctl','--endpoints=https://127.0.1.1:23379','--cacert='+str(w/'ca.crt'),'--cert='+str(w/'admin.crt'),'--key='+str(w/'admin.key'),'--command-timeout=3s']
            wait_for(lambda: run(ctlbase+['endpoint','health']))
            run(ctlbase+['user','add','root','--no-password']);run(ctlbase+['user','grant-role','root','root']);run(ctlbase+['auth','enable'])
            run(ctlbase+['user','add','patroni-pg-prod','--interactive=false'],input='fixture-etcd-password\n')
            run(ctlbase+['role','add','patroni-pg-prod']);run(ctlbase+['role','grant-permission','patroni-pg-prod','readwrite','/homelab/patroni/pg-prod/','--prefix=true']);run(ctlbase+['user','grant-role','patroni-pg-prod','patroni-pg-prod'])
            values={}
            for index,name in enumerate(['p1','p2','dev']):
                d=pg/name;cfg=d/'config';cfg.mkdir(parents=True)
                address=f'127.0.2.{index+1}'
                cert(cfg,'server','pg-fixture.test','serverAuth',f'DNS:pg-fixture.test,IP:{address}')
                cert(cfg,'etcd','','clientAuth','DNS:etcd-patroni-pg-prod')
                v=dict(pg_instance='dev' if name=='dev' else 'prod',pg_member=name,pg_address=address,
                       pg_profile=dict(user='postgres',port=25432,api_port=28008,shared_buffers='32MB',max_connections=30),
                       pg_credentials=dict(superuser_password='fixture-superuser-password',replication_password='fixture-replication-password',rest_password='fixture-rest-password'),
                       pg_etcd_credentials=dict(username='patroni-pg-prod',password='fixture-etcd-password'),
                       pg_etcd_endpoints=[f'{h["etcd_address"]}:23379' for h in hosts.values()],
                       pg_config_dir='/node/config',pg_parent_dir='/node',pg_data_dir='/node/data',pg_socket_dir='/node/socket',
                       pg_bin_dir='/usr/lib/postgresql/18/bin',pg_replication_addresses=['127.0.0.0/8'],pg_client_cidrs=['127.0.0.0/8'],
                       pg_repo_remote=False,pg_repo_path='/repo')
                values[name]=v
                for template in (['postgresql.conf','pg_hba.conf'] if name=='dev' else ['patroni.yml','pgbackrest.conf']):
                    (cfg/template).write_text(env.get_template(template+'.j2').render(**v))
                for folder in ['socket','backup-lock','backup-spool']:(d/folder).mkdir()
            (pg/'repo').mkdir();(pg/'restore').mkdir();(pg/'pitr').mkdir()
            uid=os.getuid();gid=os.getgid()
            run(['docker','run','--rm','-v',f'{pg}:/fixture',IMAGE,'chown','-R','999:999','/fixture'])

            def start(name, command):
                cname=prefix+'-'+name
                args=['docker','run','-d','--name',cname,'--network','host','--user','999:999','--memory','512m','--cpus','1',
                      '-v',f'{pg/name}:/node','-v',f'{pg/"repo"}:/repo','-v',f'{pg/"restore"}:/restore','-v',f'{pg/"pitr"}:/pitr',IMAGE,*command]
                run(args);containers.append(cname);return cname

            def sql(name, query, tcp=False, password='fixture-superuser-password', user='postgres'):
                command=['docker','exec','-i',prefix+'-'+name,'psql','-X','-v','ON_ERROR_STOP=1','-At']
                if tcp:
                    command+=['host=pg-fixture.test hostaddr='+values[name]['pg_address']+' port=25432 user='+user+' dbname=postgres sslmode=verify-full sslrootcert=/node/config/ca.crt password='+password]
                else: command+=['-h','/node/socket','-p','25432','-U','postgres','postgres']
                return run(command,input=query).stdout.strip()

            start('p1',['/opt/patroni/bin/patroni','/node/config/patroni.yml'])
            wait_for(lambda: sql('p1','SELECT NOT pg_is_in_recovery()')=='t')
            start('p2',['/opt/patroni/bin/patroni','/node/config/patroni.yml'])
            wait_for(lambda: sql('p2','SELECT pg_is_in_recovery()')=='t')
            assert sql('p1','SHOW max_connections')=='30'
            print('PASS: PG 18 primary and streaming standby through authenticated mTLS etcd3',flush=True)
            # 开发实例直接使用同套配置模板；与生产不共享数据目录或 DCS。
            run(['docker','run','--rm','--user','999:999','-v',f'{pg/"dev"}:/node',IMAGE,'/usr/lib/postgresql/18/bin/initdb','-D','/node/data','--username=postgres','--auth-local=peer','--auth-host=scram-sha-256'])
            start('dev',['/usr/lib/postgresql/18/bin/postgres','-D','/node/data','-c','config_file=/node/config/postgresql.conf'])
            wait_for(lambda: sql('dev','SELECT 1')=='1')
            sql('p1',"CREATE TABLE probe(id integer primary key); INSERT INTO probe VALUES (1); CREATE ROLE ayatori LOGIN NOSUPERUSER CREATEDB CREATEROLE PASSWORD 'fixture-ayatori-password';")
            assert sql('p1',"SELECT NOT rolsuper AND rolcreatedb AND rolcreaterole FROM pg_roles WHERE rolname=current_user",True,'fixture-ayatori-password','ayatori')=='t'
            sql('p1',"CREATE ROLE tenant_owner NOLOGIN; GRANT tenant_owner TO ayatori WITH SET TRUE; CREATE DATABASE tenant_probe OWNER tenant_owner;",True,'fixture-ayatori-password','ayatori')
            assert sql('dev',"SELECT to_regclass('public.probe') IS NULL")=='t'
            wait_for(lambda: sql('p2','SELECT count(*) FROM probe')=='1')
            # 相同 stanza 在两节点上使用同一隔离测试仓库；生产 SSH 传输另行验收。
            def backrest(name,*args):return run(['docker','exec',prefix+'-'+name,'pgbackrest','--config=/node/config/pgbackrest.conf','--stanza=prod',*args])
            backrest('p1','stanza-create');backrest('p1','check');backrest('p1','--type=full','backup')
            initial_backup=json.loads(backrest('p1','--output=json','info').stdout)[0]['backup'][-1]['label']
            recovery_target=sql('p1','SELECT clock_timestamp()::text')
            print('PASS: separate dev, TLS verify-full, non-superuser Ayatori native privileges, initial backup',flush=True)
            proxycfg=w/'proxy.cfg'
            # 文件父目录仍由调用者拥有，新增代理配置不触碰 PG 文件。
            proxycfg.write_text(env.get_template('haproxy.cfg.j2').render(pg_proxy_bind='127.0.2.10:26432',pg_proxy_members=[dict(name=n,address=values[n]['pg_address'],port=25432,api_port=28008) for n in ['p1','p2']]))
            cname=prefix+'-proxy';run(['docker','run','-d','--name',cname,'--network','host','-v',f'{proxycfg}:/proxy.cfg:ro',IMAGE,'haproxy','-f','/proxy.cfg','-db']);containers.append(cname)
            def proxy_sql():return run(['docker','exec',prefix+'-dev','psql','-X','-At','host=127.0.2.10 port=26432 user=ayatori dbname=postgres sslmode=verify-ca sslrootcert=/node/config/ca.crt password=fixture-ayatori-password','-c','SELECT pg_is_in_recovery()']).stdout.strip()
            wait_for(lambda: proxy_sql()=='f')
            began=time.monotonic();run(['docker','kill',prefix+'-p1'])
            wait_for(lambda: sql('p2','SELECT NOT pg_is_in_recovery()')=='t')
            wait_for(lambda: proxy_sql()=='f')
            rto=time.monotonic()-began
            sql('p2','INSERT INTO probe VALUES (2)');backrest('p2','check');backrest('p2','--type=full','backup')
            assert sql('dev','SELECT 1')=='1'
            print(f'PASS: automatic failover + proxy routing in {rto:.1f}s; dev unaffected; backup after failover',flush=True)
            run(['docker','start',prefix+'-p1'])
            wait_for(lambda: sql('p1','SELECT pg_is_in_recovery()')=='t')
            wait_for(lambda: sql('p1','SELECT count(*) FROM probe')=='2')
            assert sql('p2','SELECT NOT pg_is_in_recovery()')=='t'
            print('PASS: old primary rejoins as replica without stealing leadership',flush=True)
            backrest('p2','--pg1-path=/restore','--type=immediate','restore')
            # 恢复出的副本不连接 DCS，不向生产/测试 stanza 继续归档。
            cname=prefix+'-restore';run(['docker','run','-d','--name',cname,'--network','host','--user','999:999','-v',f'{pg/"restore"}:/restore','-v',f'{pg/"p2"}:/node','-v',f'{pg/"repo"}:/repo',IMAGE,'postgres','-D','/restore','-c','listen_addresses=127.0.2.20','-p','27432','-c','unix_socket_directories=/tmp','-c','archive_mode=off','-c','hot_standby=on']);containers.append(cname)
            def restored():return run(['docker','exec',cname,'psql','-X','-At','-h','/tmp','-p','27432','-U','postgres','postgres','-c','SELECT count(*) FROM probe']).stdout.strip()
            wait_for(lambda: restored()=='2')
            print('PASS: isolated restore contains both pre/post-failover rows',flush=True)
            backrest('p2','--pg1-path=/pitr','--set='+initial_backup,'--type=time',
                     '--target='+recovery_target,'--target-action=promote','restore')
            cname=prefix+'-pitr'
            run(['docker','run','-d','--name',cname,'--network','host','--user','999:999',
                 '-v',f'{pg/"pitr"}:/pitr','-v',f'{pg/"p2"}:/node','-v',f'{pg/"repo"}:/repo',IMAGE,
                 'postgres','-D','/pitr','-c','listen_addresses=127.0.2.21','-p','27433',
                 '-c','unix_socket_directories=/tmp','-c','archive_mode=off']);containers.append(cname)
            def pitr_rows():
                return run(['docker','exec',cname,'psql','-X','-At','-h','/tmp','-p','27433',
                            '-U','postgres','postgres','-c','SELECT count(*) FROM probe']).stdout.strip()
            wait_for(lambda: pitr_rows()=='1')
            print('PASS: WAL point-in-time restore recovers pre-failover state from initial backup',flush=True)
            for process in processes[1:]:
                process.terminate(); process.wait(timeout=10)
            def write_fenced():
                try:
                    sql('p2','INSERT INTO probe VALUES (3) ON CONFLICT DO NOTHING')
                    return False
                except subprocess.CalledProcessError:
                    return True
            wait_for(write_fenced)
            print('PASS: DCS majority loss eventually prevents primary writes (failsafe disabled)',flush=True)
        except Exception:
            for container in containers:
                result=subprocess.run(['docker','logs','--tail','15',container],capture_output=True,text=True)
                print(container,result.stdout,result.stderr)
            raise
        finally:
            for container in reversed(containers):subprocess.run(['docker','rm','-f',container],capture_output=True)
            for p in processes:
                p.terminate()
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:p.kill();p.wait()
            for h in handles:h.close()
            subprocess.run(['docker','run','--rm','-v',f'{pg}:/fixture',IMAGE,'chown','-R',f'{os.getuid()}:{os.getgid()}','/fixture'],capture_output=True)


if __name__=='__main__':main()
