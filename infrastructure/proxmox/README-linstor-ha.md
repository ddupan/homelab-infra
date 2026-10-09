# LINSTOR controller HA (#295)

The controller DB (H2, ~1 MB) lives on `linstor_db`, a 200M three-replica DRBD resource on the
`ssd` pool, mounted at `/var/lib/linstor`. `drbd-reactor`'s promoter starts
`var-lib-linstor.mount` + `linstor-controller.service` on whichever node holds it Primary;
`linstor-controller` is **disabled on every node**. PVE `storage.cfg` and
`/etc/linstor/linstor-client.conf` list all three node addresses. Procedure follows the
LINSTOR User Guide, "Creating a highly available LINSTOR cluster".

## Moving parts

| piece | file | note |
|---|---|---|
| one-way migration | `ansible/linstor-ha-migrate.yml` (`-e linstor_ha_migrate=true`) | creates `linstor-db-grp`/`linstor_db`, moves the DB, then applies the steady state |
| steady state | role `pve_linstor`, `pve_linstor_controller_ha: true` → `tasks/controller_ha.yml` | refuses to run if `linstor_db` does not exist |
| promoter | `/etc/drbd-reactor.d/linstor_db.toml` | drbd-reactor is also the Prometheus exporter (`pve_monitoring`) |
| DB ownership | `linstor-controller.service.d/homelab-db-owner.conf` | `chown` before start: the unit uses `DynamicUser`, its uid is a hash and could differ per node |
| monitoring | `platform/observability/metrics/{scrapes,rules}/linstor.yaml` | all three nodes scraped; alerts on 0 or >1 active controllers |

Deliberate choices:
- **Only `linstor_db` goes to the promoter.** Guest volumes stay with PVE's `ha-manager`; two
  failover systems on one resource fight each other.
- `stop-services-on-exit` stays at its default `false`, so restarting `drbd-reactor` does not
  stop the controller. No `on-drbd-demote-failure` action: PVE fencing is already armed.
- `auto-promote=no`, `quorum=majority`, `on-no-quorum=io-error` on the group: the promoter, not
  whoever opens the device, decides where the DB is mounted.
- LINSTOR ≥ 1.32: the `LS_KEEP_RES=linstor_db` satellite override from the guide is not needed.

## Migration record (2026-10-09)

- `linstor-ha-migrate.yml` run once: `linstor_db` on `/dev/drbd1014`, 3× UpToDate; DB backup
  `/root/linstor-db-pre-ha-20261009T063652Z.tgz` and `/var/lib/linstor.orig` kept on pve1.
- Failover test: `drbd-reactorctl evict linstor_db` on pve1 → **pve2 took over in ~10 s**; all
  satellites back ONLINE ~19 s after takeover (pve1's client briefly saw 2/3 ONLINE meanwhile).
  The DB stayed writable on pve2 (ownership drop-in did its job).
- Re-runs of both `linstor-ha-migrate.yml` and `linstor.yml --tags linstor_config` with the
  controller on **pve2** → `changed=0`, controller untouched.

Bugs found by that test and fixed before merge — keep them in mind when editing the play:
- "already migrated" must be judged **cluster-wide** (local DRBD mount, or `.orig` exists, or
  `linstor_db` Primary anywhere). Checking only the local mount would restart the migration on
  pve1 once the DB had failed over elsewhere.
- The "stop stray controllers" step must skip nodes whose controller the promoter already
  manages — after a failover that controller is the live one.
- Right after `drbd-reactor` restarts, the controller can read `activating`; the verify step
  waits for it to settle.

## Day-to-day

```bash
drbd-reactorctl status linstor_db          # any node: who runs it, unit health
drbd-reactorctl evict linstor_db           # on the active node: hand it to another node
systemctl is-enabled linstor-controller    # must be "disabled" everywhere
```

⚠ A Debian package upgrade of `linstor-controller` may re-enable the unit. `linstor.yml`
re-disables it; `LinstorMultipleControllers` catches a second controller in the meantime.

## Rollback (back to a single controller on pve1)

1. On every node: `rm /etc/drbd-reactor.d/linstor_db.toml && systemctl restart drbd-reactor`
   (the promoter stops managing it; running services are left alone).
2. On the active node: `systemctl stop linstor-controller var-lib-linstor.mount`;
   `drbdadm secondary linstor_db`.
3. On pve1: copy the DB back — from the mounted `linstor_db` if it is newer than
   `/var/lib/linstor.orig`, otherwise `/var/lib/linstor.orig` or `/root/linstor-db-pre-ha-*.tgz`
   — into a plain `/var/lib/linstor`, then `systemctl enable --now linstor-controller`.
4. Set `pve_linstor_controller_ha: false` and run `linstor.yml --tags linstor_config` (points
   client and storage.cfg back at pve1 only, stops controllers elsewhere).
5. Optionally `linstor resource-definition delete linstor_db` once nothing mounts it.
