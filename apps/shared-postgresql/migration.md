# Shared PostgreSQL Migration Runbook

## Target

- CloudNativePG cluster: `shared-postgresql`
- Namespace: `shared-db`
- Compatibility service: `shared-postgresql.shared-db.svc.cluster.local:5432`
- CNPG rw service: `shared-postgresql-rw.shared-db.svc.cluster.local:5432`
- Tailscale service: `shared-postgresql-tailscale.shared-db.svc.cluster.local:5432`

## Apply order

1. Create the CNPG superuser secret
2. Apply `shared-postgresql/cloudnativepg-cluster.yaml`
3. Wait for the cluster to become ready
4. Restore the databases and validate against the CNPG `rw` Service
5. Remove the legacy Helm release so the old Service can be removed cleanly
6. Apply `shared-postgresql/shared-postgresql-service.yaml`
7. Validate app connectivity through the compatibility and Tailscale Services

## Storage preflight

```bash
kubectl get storageclass localpv-zfs-ceph
kubectl get pods -n openebs
```

Make sure the OpenEBS ZFS storage class exists and the OpenEBS components are healthy before starting the cutover.

## Reconcile source passwords

The following passwords are the current source of truth for the migration:

- `SOURCE_POSTGRES_PASSWORD` for the source dump and CNPG superuser secret
- `OLD_GITEA_PASSWORD` and `OLD_CASDOOR_PASSWORD` for the restored app logins

## Create the CNPG secret

```bash
kubectl create secret generic shared-postgresql-superuser-secret \
  -n shared-db \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=postgres \
  --from-literal=password="$SOURCE_POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Dump from the old instance

Pause writes from dependent apps first.

```bash
kubectl get pod -n shared-db -l app.kubernetes.io/component=primary,app.kubernetes.io/instance=shared-postgresql,app.kubernetes.io/name=postgresql --show-labels
SOURCE_POD="$(kubectl get pod -n shared-db -l app.kubernetes.io/component=primary,app.kubernetes.io/instance=shared-postgresql,app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')"
kubectl exec -n shared-db "$SOURCE_POD" -- sh -lc "PGPASSWORD='$SOURCE_POSTGRES_PASSWORD' pg_dumpall -h 127.0.0.1 -U postgres --globals-only" > globals.sql
kubectl exec -n shared-db "$SOURCE_POD" -- sh -lc "PGPASSWORD='$SOURCE_POSTGRES_PASSWORD' pg_dump -h 127.0.0.1 -U postgres -Fc -d e5renew" > e5renew.dump
kubectl exec -n shared-db "$SOURCE_POD" -- sh -lc "PGPASSWORD='$SOURCE_POSTGRES_PASSWORD' pg_dump -h 127.0.0.1 -U postgres -Fc -d gitea" > gitea.dump
kubectl exec -n shared-db "$SOURCE_POD" -- sh -lc "PGPASSWORD='$SOURCE_POSTGRES_PASSWORD' pg_dump -h 127.0.0.1 -U postgres -Fc -d casdoor" > casdoor.dump
```

## Restore into CNPG

`globals.sql` restores the roles and passwords from the source cluster. The init SQL only creates the application databases and grants.

```bash
cat globals.sql > globals.with-postgres-reset.sql
printf "ALTER ROLE postgres PASSWORD :'source_postgres_password';\n" >> globals.with-postgres-reset.sql
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -v source_postgres_password="$SOURCE_POSTGRES_PASSWORD" -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d postgres -f globals.with-postgres-reset.sql
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d postgres -f shared-postgresql/shared-postgresql-init.sql
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" pg_restore -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d e5renew e5renew.dump
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" pg_restore -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d gitea gitea.dump
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" pg_restore -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d casdoor casdoor.dump
```

## Pre-cutover validation

```bash
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d e5renew -c 'select 1;'
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -h shared-postgresql-rw.shared-db.svc.cluster.local -U postgres -d e5renew -c 'create table if not exists migration_check(id int); insert into migration_check values (1); delete from migration_check; drop table migration_check;'
PGPASSWORD="$OLD_GITEA_PASSWORD" psql -h shared-postgresql-rw.shared-db.svc.cluster.local -U gitea -d gitea -c 'create table if not exists migration_check(id int); insert into migration_check values (1); delete from migration_check; drop table migration_check;'
PGPASSWORD="$OLD_CASDOOR_PASSWORD" psql -h shared-postgresql-rw.shared-db.svc.cluster.local -U casdoor -d casdoor -c 'create table if not exists migration_check(id int); insert into migration_check values (1); delete from migration_check; drop table migration_check;'
```

## Post-cutover validation

```bash
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -h shared-postgresql.shared-db.svc.cluster.local -U postgres -d e5renew -c 'select 1;'
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -h shared-postgresql.shared-db.svc.cluster.local -U postgres -d e5renew -c 'create table if not exists migration_check(id int); insert into migration_check values (1); delete from migration_check; drop table migration_check;'
PGPASSWORD="$OLD_GITEA_PASSWORD" psql -h shared-postgresql.shared-db.svc.cluster.local -U gitea -d gitea -c 'create table if not exists migration_check(id int); insert into migration_check values (1); delete from migration_check; drop table migration_check;'
PGPASSWORD="$OLD_CASDOOR_PASSWORD" psql -h shared-postgresql.shared-db.svc.cluster.local -U casdoor -d casdoor -c 'create table if not exists migration_check(id int); insert into migration_check values (1); delete from migration_check; drop table migration_check;'
PGPASSWORD="$SOURCE_POSTGRES_PASSWORD" psql -h shared-postgresql-tailscale.shared-db.svc.cluster.local -U postgres -d e5renew -c 'select 1;'
```

## Rollback

- Keep the old Helm-based PostgreSQL deployment until validation passes.
- If restore fails, delete the CNPG cluster.
- Delete the CNPG compatibility Service with `kubectl delete -f shared-postgresql/shared-postgresql-service.yaml` so the `shared-postgresql` hostname is free for the legacy release again.
- Reapply the legacy Helm release.
- After the old Helm release is back, regenerate the Tailscale Service from the live pod labels and apply it:

```bash
python - <<'PY' | kubectl apply -f -
import json
import subprocess
import yaml

pod = subprocess.check_output([
    'kubectl', 'get', 'pod', '-n', 'shared-db',
    '-l', 'app.kubernetes.io/component=primary,app.kubernetes.io/instance=shared-postgresql,app.kubernetes.io/name=postgresql',
    '-o', 'json'
], text=True)
labels = json.loads(pod)['items'][0]['metadata']['labels']
selector = {
    'app.kubernetes.io/component': labels['app.kubernetes.io/component'],
    'app.kubernetes.io/instance': labels['app.kubernetes.io/instance'],
    'app.kubernetes.io/name': labels['app.kubernetes.io/name'],
}
service = {
    'apiVersion': 'v1',
    'kind': 'Service',
    'metadata': {
        'name': 'shared-postgresql-tailscale',
        'namespace': 'shared-db',
    },
    'spec': {
        'type': 'LoadBalancer',
        'loadBalancerClass': 'tailscale',
        'ports': [
            {
                'name': 'tcp-postgresql',
                'port': 5432,
                'protocol': 'TCP',
                'targetPort': 5432,
            }
        ],
        'selector': selector,
    },
}
print(yaml.safe_dump(service, sort_keys=False))
PY
```

- Do not delete the old PVC until the new cluster is verified.
