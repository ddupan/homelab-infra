# PostgreSQL CloudNativePG Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy shared PostgreSQL deployment with a single-instance CloudNativePG cluster on OpenEBS ZFS while preserving the existing `shared-postgresql` service name for the apps that already depend on it.

**Architecture:** Keep the old PostgreSQL deployment alive until the new CNPG cluster is ready, then migrate data with a logical dump/restore, swap the service endpoints, and retire the Helm-based deployment only after validation passes. The new cluster stays single-instance because there is only one worker node.

**Tech Stack:** Kubernetes manifests, CloudNativePG operator, OpenEBS ZFS storage, `kubectl`, PostgreSQL client tools.

---

## File Map

- `shared-postgresql/cloudnativepg-cluster.yaml`: new authoritative CNPG cluster manifest.
- `shared-postgresql/tailscale-loadbalancer.yaml`: keep the existing external service, but retarget it to the CNPG primary during cutover.
- `shared-postgresql/shared-postgresql-values.yaml`: legacy Helm values to delete after the rollback window closes.
- `shared-postgresql/shared-postgresql-init.sql`: reusable SQL used during migration to recreate app databases and roles.
- `shared-postgresql/migration.md`: runbook for dump, restore, cutover, and rollback.

### Task 1: Add the CNPG cluster manifest

**Files:**
- Create: `shared-postgresql/cloudnativepg-cluster.yaml`

- [ ] **Step 1: Confirm the OpenEBS ZFS storage class name**

Run: `kubectl get storageclass`

Expected: one OpenEBS-backed ZFS class is available and can be copied into `shared-postgresql/cloudnativepg-cluster.yaml` before apply.

- [ ] **Step 2: Write the cluster manifest**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: shared-postgresql
  namespace: shared-db
spec:
  instances: 1
  enableSuperuserAccess: true
  storage:
    size: 10Gi
  bootstrap:
    initdb:
      database: shared_data
      owner: sharedadmin
```

Add the `storage.storageClass` line using the exact OpenEBS ZFS class name discovered in Step 1.

- [ ] **Step 3: Verify the manifest is structurally valid**

Run: `kubectl apply --dry-run=server -f shared-postgresql/cloudnativepg-cluster.yaml`

Expected: the API server accepts the `Cluster` object once the CNPG CRD is installed.

- [ ] **Step 4: Apply the cluster manifest in the staging namespace**

Run: `kubectl apply -f shared-postgresql/cloudnativepg-cluster.yaml`

Expected: the CNPG cluster is created and starts provisioning a single primary pod.

- [ ] **Step 5: Wait for the cluster to become ready**

Run: `kubectl wait -n shared-db --for=condition=Ready cluster/shared-postgresql --timeout=15m`

Expected: the cluster reaches a ready state before any data migration begins.

### Task 2: Write the migration runbook

**Files:**
- Create: `shared-postgresql/migration.md`

- [ ] **Step 1: Document the source and target endpoints**

```text
Source service: shared-postgresql.shared-db.svc.cluster.local:5432
Target rw service: shared-postgresql-rw.shared-db.svc.cluster.local:5432
```

- [ ] **Step 2: Document the dump and restore commands**

```text
Pause writes from the dependent apps before taking the dump so the logical backup is consistent.
```

```bash
PGPASSWORD="$OLD_SHAREDADMIN_PASSWORD" pg_dump -h shared-postgresql.shared-db.svc.cluster.local -U sharedadmin -Fc -d shared_data -f shared_data.dump
PGPASSWORD="$OLD_GITEA_PASSWORD" pg_dump -h shared-postgresql.shared-db.svc.cluster.local -U gitea -Fc -d gitea -f gitea.dump
PGPASSWORD="$OLD_CASDOOR_PASSWORD" pg_dump -h shared-postgresql.shared-db.svc.cluster.local -U casdoor -Fc -d casdoor -f casdoor.dump

PGPASSWORD="$NEW_SHAREDADMIN_PASSWORD" psql -h shared-postgresql-rw.shared-db.svc.cluster.local -U sharedadmin -d postgres -f shared-postgresql/shared-postgresql-init.sql
PGPASSWORD="$NEW_SHAREDADMIN_PASSWORD" pg_restore -h shared-postgresql-rw.shared-db.svc.cluster.local -U sharedadmin -d shared_data shared_data.dump
PGPASSWORD="$NEW_GITEA_PASSWORD" pg_restore -h shared-postgresql-rw.shared-db.svc.cluster.local -U gitea -d gitea gitea.dump
PGPASSWORD="$NEW_CASDOOR_PASSWORD" pg_restore -h shared-postgresql-rw.shared-db.svc.cluster.local -U casdoor -d casdoor casdoor.dump
```

- [ ] **Step 3: Document the rollback decision point**

```text
If restore or validation fails, keep the old Helm deployment active and do not delete its Service or PVC.
```

- [ ] **Step 4: Review the runbook for exact cutover order**

Expected: the document explains that the old service stays live until data restore and app checks pass.

### Task 3: Cut over services to CNPG

**Files:**
- Modify: `shared-postgresql/tailscale-loadbalancer.yaml`
- Create: `shared-postgresql/shared-postgresql-service.yaml`

- [ ] **Step 1: Add the compatibility ClusterIP service**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: shared-postgresql
  namespace: shared-db
spec:
  type: ClusterIP
  selector:
    cnpg.io/cluster: shared-postgresql
    cnpg.io/instanceRole: primary
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
```

- [ ] **Step 2: Update the Tailscale LoadBalancer selector**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: shared-postgresql-tailscale
  namespace: shared-db
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  ports:
    - name: tcp-postgresql
      port: 5432
      protocol: TCP
      targetPort: 5432
  selector:
    cnpg.io/cluster: shared-postgresql
    cnpg.io/instanceRole: primary
```

- [ ] **Step 3: Apply the compatibility service only after the Helm release is removed**

Run: `kubectl apply -f shared-postgresql/shared-postgresql-service.yaml -f shared-postgresql/tailscale-loadbalancer.yaml`

Expected: the original `shared-postgresql` hostname resolves to the CNPG primary and Tailscale reaches the same pod.

- [ ] **Step 4: Validate application connectivity**

Run: `PGPASSWORD="$NEW_SHAREDADMIN_PASSWORD" psql -h shared-postgresql.shared-db.svc.cluster.local -U sharedadmin -d shared_data -c 'select 1;'`

Expected: the compatibility Service resolves and accepts a real PostgreSQL login after the swap.

### Task 4: Remove the legacy Helm deployment

**Files:**
- Delete: `shared-postgresql/shared-postgresql-values.yaml`

- [ ] **Step 1: Confirm all dependent apps are using the CNPG-backed Service**

Run: `kubectl get endpoints -n shared-db shared-postgresql`

Expected: the endpoints point at the CNPG pod, not the old Helm chart pod.

- [ ] **Step 2: Remove the old Helm values file after the rollback window**

Run: `git rm shared-postgresql/shared-postgresql-values.yaml`

Expected: the repository no longer advertises the retired deployment path once cutover is stable.

- [ ] **Step 3: Keep the bootstrap SQL file as the migration reference**

Expected: `shared-postgresql/shared-postgresql-init.sql` remains in the tree until the migration is fully complete and documented.

- [ ] **Step 4: Re-run the manifest validation pass**

Run: `kubectl apply --dry-run=server -f shared-postgresql/`

Expected: the remaining manifest set is clean and consistent.
