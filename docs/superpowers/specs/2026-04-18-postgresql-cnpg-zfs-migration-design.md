# PostgreSQL Migration Design

## Goal
Move the current shared PostgreSQL deployment to CloudNativePG and back it with the existing OpenEBS ZFS storage layer.

The target state is a single PostgreSQL cluster managed by CloudNativePG, running one instance on the only worker node, with one shared database service for the apps that already use `shared-postgresql`.

## Current State
- PostgreSQL is currently deployed from chart values in `shared-postgresql/shared-postgresql-values.yaml`.
- Storage currently uses `local-path`.
- Apps such as Gitea and Casdoor point at the shared PostgreSQL service.
- There is an init SQL file for bootstrap data in `shared-postgresql/shared-postgresql-init.sql`.

## Target State
- CloudNativePG manages the PostgreSQL lifecycle.
- Storage comes from the OpenEBS-provided ZFS-backed `StorageClass`.
- The cluster runs with `instances: 1` because there is only one worker node.
- Existing app databases remain in the same PostgreSQL cluster.
- A compatibility Kubernetes `Service` preserves the existing shared database hostname or provides an equivalent stable alias.

## Non-Goals
- High availability across multiple nodes.
- Automatic failover.
- Database sharding or splitting apps into separate clusters.
- Changing application-level schemas unless required by migration.

## Approach
1. Provision or verify the OpenEBS ZFS `StorageClass` suitable for PostgreSQL PVCs.
2. Deploy CloudNativePG and create one cluster with a single instance.
3. Create the required role and database layout for the shared apps.
4. Migrate data from the current PostgreSQL instance with a logical dump and restore.
5. Cut over workloads to the new service.
6. Validate app logins, migrations, and basic read/write behavior.

## Migration Plan
### Phase 1: Storage
- Confirm the OpenEBS ZFS components are installed and healthy.
- Create a dedicated PostgreSQL `StorageClass` for CNPG.
- Use a single PVC for the primary instance.

### Phase 2: Database Deployment
- Install CloudNativePG.
- Create a `Cluster` manifest with one instance.
- Set resource requests and limits close to the current PostgreSQL footprint.
- Mount any required bootstrap SQL through CloudNativePG-supported init methods.

### Phase 3: Data Migration
- Quiesce writes on the current PostgreSQL instance.
- Take a logical backup of the existing databases and roles, including globals such as users and grants.
- Restore into the new CloudNativePG cluster.
- Recreate any app-specific users, grants, and schemas that are not captured automatically.

### Phase 4: Cutover
- Point app secrets or connection settings at the new CNPG service.
- Restart or roll the dependent workloads.
- Verify each app can connect and operate normally.

### Phase 5: Cleanup
- Keep the old deployment available until validation completes.
- Remove the old PostgreSQL deployment only after the new cluster is confirmed healthy.

## Risks
- OpenEBS ZFS must be healthy before PostgreSQL migration starts.
- Single-node deployment means node failure still causes downtime.
- Logical restore can miss permissions or extension details if the old instance has custom setup.
- Existing app passwords should be preserved or rotated carefully during cutover.

## Validation
- CNPG cluster reports healthy.
- PVC is bound on the ZFS-backed storage class.
- Existing apps can connect using the shared PostgreSQL service.
- Basic read/write checks succeed for each app database.
- Restarting the PostgreSQL pod does not lose data.

## Rollback
- If restore or validation fails, keep the current PostgreSQL deployment active and point apps back to the old service.
- Do not delete the old PVC or deployment until the new cluster passes validation.
