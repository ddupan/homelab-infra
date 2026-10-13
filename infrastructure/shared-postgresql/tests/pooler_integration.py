"""连接池的隔离验证：直接取 pooler.yml、pgbouncer.ini.j2 与 patroni.yml.j2 的 HBA 段的真实内容，
在临时容器里验证 auth_query + SCRAM 透传、verify-full、拒绝 superuser/复制角色、transaction 模式下的
命名预编译语句与连接复用。用法：python3 tests/pooler_integration.py（需要 integration.py 构建的镜像）。"""
import os, subprocess, sys, yaml, jinja2, pathlib, time
A = pathlib.Path(__file__).resolve().parent.parent/'ansible'
import json
env = jinja2.Environment(undefined=jinja2.ChainableUndefined)
env.filters.update(to_json=json.dumps, b64decode=lambda s: s, mandatory=lambda s: s)
gv = yaml.safe_load((A/'inventory/group_vars/all.yml').read_text())
v = dict(gv, pg_profile=dict(gv['pg_profiles']['prod'], user='postgres'), pg_config_dir='/cfg',
         pg_socket_dir='/run/pg', pg_address='127.0.0.1', pg_instance='prod')
t = (A/'roles/pg_instance/templates/patroni.yml.j2').read_text()
t = t[t.index('  pg_hba:'):t.index('  remove_data_directory')]  # 只渲染 HBA/ident 段
patroni = yaml.safe_load(env.from_string(t).render(**v))
hba = '\n'.join(patroni['pg_hba'])+'\n'; ident = '\n'.join(patroni['pg_ident'])+'\n'
ini = env.from_string((A/'templates/pgbouncer.ini.j2').read_text()).render(**v)
plays = yaml.safe_load((A/'pooler.yml').read_text())
p2 = plays[1]; v2 = dict(v, pg_pooler_lookup_body=p2['vars']['pg_pooler_lookup_body'])
check_sql = env.from_string(p2['tasks'][0]['ansible.builtin.command']['stdin']).render(**v2)
create_sql = env.from_string(p2['tasks'][1]['ansible.builtin.command']['stdin']).render(**v2)
hba_check = env.from_string(plays[0]['tasks'][0]['vars']['pg_pooler_hba_check']).render(**v)
C = 'pooler-check'
def sh(cmd, user='postgres', input=None, ok=True):
    r = subprocess.run(['docker','exec','-i','-u',user,C,'bash','-c',cmd], input=input, text=True, capture_output=True)
    if ok and r.returncode: sys.exit(f'FAIL {cmd}\n{r.stdout}{r.stderr}')
    return r
subprocess.run(['docker','rm','-f',C], capture_output=True)
subprocess.run(['docker','run','-d','--name',C,os.environ.get('PG_TEST_IMAGE','homelab-pg-test:18-patroni4.1.5'),'sleep','infinity'], check=True, capture_output=True)
try:
    for i in range(5):
        if sh(f'apt-get update -qq && apt-get install -y -qq pgbouncer >/dev/null', user='root', ok=False).returncode == 0: break
        time.sleep(10)
    else: sys.exit('FAIL install pgbouncer')
    print(sh('pgbouncer --version', user='root').stdout.splitlines()[0])
    sh('mkdir -p /cfg /run/pg && chown postgres /cfg /run/pg && chmod 700 /run/pg', user='root')
    sh('cd /cfg && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout server.key -out server.crt -subj /CN=localhost -days 1 2>/dev/null && cp server.crt ca.crt && chmod 600 server.key')
    sh('initdb -D /tmp/d -U postgres >/dev/null')
    sh('cat > /tmp/d/pg_hba.conf', input=hba); sh('cat > /tmp/d/pg_ident.conf', input=ident)
    sh("pg_ctl -D /tmp/d -w -o \"-c listen_addresses='' -c unix_socket_directories=/run/pg\" start >/dev/null")
    psql = 'psql -X -At -v ON_ERROR_STOP=1 -h /run/pg -d postgres'
    assert sh(f'{psql} -c "{hba_check}"').stdout.strip() == 't', 'hba check'
    assert sh(psql, input=check_sql).stdout.strip() == 'f|f'
    sh(psql, input=create_sql)
    assert sh(psql, input=check_sql).stdout.strip() == 'f|t', 'idempotency check after create'
    sh(psql, input=create_sql); assert sh(psql, input=check_sql).stdout.strip() == 'f|t'
    sh(psql, input="CREATE ROLE app LOGIN PASSWORD 'apppw'; CREATE ROLE su LOGIN SUPERUSER PASSWORD 'supw'; CREATE ROLE repl LOGIN REPLICATION PASSWORD 'replpw'; CREATE DATABASE app OWNER app;")
    sh('cat > /cfg/pgbouncer.ini', input=ini)
    sh('nohup pgbouncer /cfg/pgbouncer.ini >/tmp/pgb.log 2>&1 &')
    time.sleep(1)
    def via(user, pw, q, db='app'):
        return sh(f"PGPASSWORD={pw} psql -X -At 'host=localhost hostaddr=127.0.0.1 port=6432 sslmode=verify-full sslrootcert=/cfg/ca.crt user={user} dbname={db}'", input=q, ok=False)
    r = via('app', 'apppw', 'SELECT current_user, ssl FROM pg_stat_ssl, pg_stat_activity WHERE false; SELECT current_user;')
    assert r.returncode == 0 and r.stdout.strip() == 'app', r.stdout + r.stderr + sh('cat /tmp/pgb.log').stdout
    print('PASS: verify-full TLS + SCRAM passthrough via auth_query')
    assert via('app', 'wrong', 'SELECT 1').returncode != 0; print('PASS: wrong password rejected')
    assert via('su', 'supw', 'SELECT 1', 'postgres').returncode != 0; print('PASS: superuser not served by pool')
    assert via('repl', 'replpw', 'SELECT 1', 'postgres').returncode != 0; print('PASS: replication role not served by pool')
    r = via('app', 'apppw', "SELECT $1::int + 1 \\parse s1\n\\bind_named s1 41 \\g\nBEGIN;\nSELECT 1;\nCOMMIT;\n\\bind_named s1 1 \\g\n")
    assert r.returncode == 0 and r.stdout.split() == ['42','BEGIN','1','COMMIT','2'], r.stdout + r.stderr
    print('PASS: named prepared statements survive transaction pooling')
    procs = [subprocess.Popen(['docker','exec','-e','PGPASSWORD=apppw',C,'psql','-X','-At','host=localhost hostaddr=127.0.0.1 port=6432 sslmode=require user=app dbname=app','-c','SELECT pg_sleep(2)'], stdout=subprocess.DEVNULL) for _ in range(12)]
    time.sleep(1)
    n = int(sh(f"{psql} -c \"SELECT count(*) FROM pg_stat_activity WHERE usename='app'\"").stdout)
    [p.wait() for p in procs]
    assert all(p.returncode == 0 for p in procs) and n <= v['pg_pooler']['default_pool_size'], n
    print(f'PASS: 12 concurrent clients used {n} server connections (pool size {v["pg_pooler"]["default_pool_size"]})')
finally:
    subprocess.run(['docker','rm','-f',C], capture_output=True)
