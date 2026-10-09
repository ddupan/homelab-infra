# Proxmox monitoring

Three sources, deployed 2026-10-05:

| what | where | covers |
|---|---|---|
| `prometheus-node-exporter` on pve1/2/3 | `ansible/monitoring.yml` → role `pve_monitoring` | host: disk, memory, PSI, systemd units (corosync, pve-cluster, pve-ha-lrm/crm, watchdog-mux) |
| `pve-quorum-metrics.timer` (30 s) | same role | `pve_corosync_{up,quorate,expected_votes,total_votes,nodes}` via the textfile collector |
| `prometheus-pve-exporter` in k3s | `platform/observability/metrics/exporters/pve-exporter.yaml` | node online (cluster view), HA state, guest locks, onboot, storage, backup coverage |

Alerts: `platform/observability/metrics/rules/proxmox.yaml`. The node-exporters are scraped
as `job=node-exporter`, so the generic host-health rules apply to the PVE nodes too.

## Why pve-exporter and not PVE's built-in OpenTelemetry metric server

PVE 9.2 ships `PVE/Status/OpenTelemetry.pm` (Datacenter → Metric Server). It was evaluated
and **not** enabled: it pushes only what pvestatd collects (resource usage), with no HA
state, no locks and no cluster-side view of which nodes are online — a node that fences
itself simply goes quiet. It also speaks OTLP/HTTP **JSON only**, which VMSingle rejects
(it takes protobuf), so it would need the OTel Collector in between plus a new ingress.

## Running it

```bash
cd infrastructure/proxmox/ansible
ansible-playbook monitoring.yml --check --diff
ansible-playbook monitoring.yml          # rerun → changed=0
```

Needs `VAULT_TOKEN` (read/write `kv/k8s/pve-exporter`) — the laptop's SPIFFE
`local-development` Bao role is enough.

**API identity.** `pve-exporter@pve`, no password, role `PVEAuditor` on `/` (read-only).
Its token `exporter` (privsep 0, so it inherits exactly that role) is created by the play and
written straight to Bao `kv/k8s/pve-exporter`; ESO syncs it into `monitoring/pve-exporter`.
A PVE token is shown **only once**, so the play refuses to continue if the token exists but
Bao has no copy. To recover or rotate:

```bash
ansible-playbook monitoring.yml -e pve_exporter_rotate_token=true
kubectl -n monitoring annotate externalsecret pve-exporter force-sync=$(date +%s) --overwrite
kubectl -n monitoring rollout restart deploy/pve-exporter
```

**Quorum.** Neither PVE API metrics nor pve-exporter expose quorate per node, and with HA
fencing armed a node that loses quorum reboots itself within about a minute, leaving no
trace — hence the textfile. `corosync-quorumtool -s` exits non-zero when the node is not
quorate; the script keeps its output anyway.

**Scrape layout.** Cluster-level data comes from `/cluster/resources`, available on any node,
so `pve-cluster` scrapes **both pve1 and pve2**: if one of them is the node that died, the
other still reports it offline. Rules deduplicate with `max without(instance)`. Node-level
collectors (onboot, replication, subscription) only answer for the node asked, so `pve-node`
scrapes all three.

## VyOS (`vyos-rtr`, 192.168.10.2)

VyOS carries far more than routing, and its config is split across three playbooks — so its
monitoring is too:

| what | deployed by | covers |
|---|---|---|
| built-in `node-exporter` + `frr-exporter` (`service monitoring prometheus`) | `ansible/vyos.yml` (role `vyos_router`) | host, interfaces, OSPF adjacency, DN42 iBGP |
| `vyos-unit-metrics.timer` → textfile | `ansible/vyos-monitoring.yml` (ssh+python, inventory `vyos_shell`) | frr, both HAProxies, kea, pdns-recursor, radvd, chrony |
| HAProxy Prometheus frontend `192.168.10.2:8405` | `../shared-postgresql/ansible/proxy.yml` | which Patroni member pg-prod routes to |
| blackbox: 4 TCP entry points + DN42 SOA via `192.168.10.2` | `platform/observability/metrics/probes/probes.yaml` | pg-prod, sandbox k3s API, opensandbox, sandbox PG, DN42 resolution |

Run order: `vyos.yml` (enables the exporters and creates the textfile dir) → `vyos-monitoring.yml`.

- VyOS's node_exporter runs only default collectors — **no systemd** — and the CLI exposes only
  a textfile switch, hence the timer. Its files live under `/config/homelab-monitoring` and a
  block in `/config/scripts/vyos-postconfig-bootup.script` re-links the units after an image
  upgrade (everything outside `/config` is reset), the same mechanism `proxy.yml` uses.
- `node_network_up` is always 0 for `wg42`: WireGuard reports operstate `unknown`. The tunnel is
  judged by the BGP session running over it instead.
- Exporters listen on `192.168.10.2` only. VyOS has **no firewall configured**; binding
  `0.0.0.0` would also expose them on the SDN VNets and `wg42`.
- ⚠ `vyos_router`'s `backup: true` pulls the **full running config** (WireGuard private key,
  login hash) into `vyos/backups/config.boot`. That directory is gitignored since 2026-10-05;
  before that the file was tracked and the history still holds the `vyos` login hash.

## LINSTOR / DRBD

| source | where | covers |
|---|---|---|
| LINSTOR controller `/metrics` | `192.168.10.4:3370` (pve1, the only controller) | satellite state, per-node volume/resource state, storage-pool capacity, error reports |
| `drbd-reactor` Prometheus plugin | each node `:9942`, installed by `monitoring.yml` | DRBD connection state, quorum, suspended IO, out-of-sync bytes, failed/unintentionally-diskless disks |

Why both: the controller only reports each node's **local** disk state. If the replication
link between two replicas breaks, both still say `UpToDate` — the volume is down to one live
copy and the controller shows nothing. Only DRBD's own connection state reveals it.

- drbd-reactor here runs **only** the Prometheus plugin. The rule is narrower than "no promoter":
  **guest volumes** must never be handed to the promoter — PVE's `ha-manager` owns their
  failover, and two failover systems on one resource fight each other. The controller's own
  `linstor_db` resource is exactly what the promoter is for — see README-linstor-ha.md (#295).
- Do not add a `node` target label to the controller scrape: LINSTOR's metrics already carry
  `node` (the satellite), and a target label would overwrite it with `pve1` for every series.
- `Diskless` devices are intentional DRBD clients (14 of them on 2026-10-09), not degraded disks.
- The controller is HA since 2026-10-09 (#295, `README-linstor-ha.md`): the scrape covers all
  three nodes on 3370 — only the promoter-elected one listens, so `up=0` on the others is normal
  — and `LinstorNoActiveController` / `LinstorMultipleControllers` alert on anything but one.

