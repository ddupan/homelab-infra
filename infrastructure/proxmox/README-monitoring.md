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
