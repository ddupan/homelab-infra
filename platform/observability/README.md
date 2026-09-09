# observability

Metrics, logs, and traces for the cluster — one VictoriaMetrics-ecosystem stack,
operator-driven, running in the `monitoring` namespace. Replaces the standalone
Docker Compose stack in `../../apps/victoriametrics/`.

## Status — DEPLOYED (2026-07-10)

Live and verified in the `monitoring` namespace (operator chart 0.66.2):
metrics (data queryable), logs (pods ingesting), traces (VTSingle CRD, verified via
Jaeger API), Grafana (3 datasources healthy, VM dashboard loaded, Tailscale ingress
`grafana.tail7e769.ts.net`, Authelia OIDC client registered). All PVCs on
`localpv-zfs-ceph`. Note the vmagent hot-reload RBAC fix (`metrics/reload-rbac.yaml`,
see `metrics/README-reload.md`) and that VL/VT CRDs are served under `.../v1`.

Still host-side (not yet done): deploy `docker-hosts/compose.yaml` on the Docker
hosts and `logs/vlogs-ingress.yaml` to push their logs.

## Decision

| Pillar   | Choice                        | Why |
| -------- | ----------------------------- | --- |
| Metrics  | **VictoriaMetrics** (VMSingle)| already in use; keep it |
| Logs     | **VictoriaLogs** (VLSingle)   | same vendor/operator, tiny footprint, LogsQL |
| Traces   | **VictoriaTraces** + OTel Collector | no extra storage deps, OTLP in, Jaeger query API |
| Collect  | vmagent (metrics), vlagent (logs), OTel Collector (traces) | native to each backend |
| Visualize| **Grafana**, one instance, 3 datasources | single pane |
| Manage   | **victoria-metrics-operator** | VMSingle/VMAgent/VMAlert/VMAlertmanager/VMRule **and** VLSingle as CRDs |
| Expose   | **Tailscale ingress** (private) + **Authelia OIDC** | admin tool: private + SSO |

Grafana's Prometheus-operator converter is on, so any chart shipping a
`ServiceMonitor`/`PodMonitor`/`PrometheusRule` is scraped automatically.

## Architecture

```
 Grafana (grafana.<tailnet>.ts.net, Authelia OIDC)
   ├── VictoriaMetrics datasource → VMSingle  ← vmagent (k8s SD, node-exporter, kubelet/cAdvisor, KSM)
   ├── VictoriaLogs   datasource → VLSingle   ← vlagent DaemonSet (pod logs)
   └── Jaeger         datasource → VictoriaTraces ← OTel Collector (OTLP 4317/4318) ← apps
 VMAlert (VMRules) → VMAlertmanager
```

## Layout

```
observability/
  namespace.yaml            monitoring namespace
  operator/                 victoria-metrics-operator (Helm)
  metrics/
    vmsingle|vmagent|vmalert|vmalertmanager.yaml   core CRs
    rules/                  VMRules ported from ../../apps/victoriametrics/rules
    exporters/              node-exporter (+VMNodeScrape), kube-state-metrics (Helm)
    scrapes/               kubelet + cAdvisor VMNodeScrapes
  logs/                     VLSingle CR + victoria-logs-collector (Helm)
  traces/                   victoria-traces-single (Helm) + OTel Collector
  grafana/                  Grafana (Helm) values, OIDC secret, install script
  docker-hosts/             per-Docker-host sidecar (cAdvisor + node-exporter + Vector)
```

## Docker hosts

The Compose services on Docker hosts (`../../apps/vlmcsd`, `../../apps/ps3netsrv`, `../../apps/netboot`, ...
and the legacy `../../apps/victoriametrics` stack) are monitored too:

- **Metrics — pull, nothing exposed.** Each host runs `docker-hosts/compose.yaml`
  (cAdvisor `:8080` + node-exporter `:9100`). The cluster's vmagent scrapes their LAN
  IPs via `metrics/scrapes/docker-hosts.yaml` (VMStaticScrape). VMSingle stays private.
- **Logs — push over the tailnet.** A **Vector** container per host tails the Docker
  socket and ships to VictoriaLogs' Elasticsearch-bulk endpoint, exposed privately as
  `vlogs.<tailnet>.ts.net` by `logs/vlogs-ingress.yaml`.

Deploy:

```bash
# cluster side (once): expose VictoriaLogs ingest + register the scrape
kubectl apply -f logs/vlogs-ingress.yaml -f metrics/scrapes/docker-hosts.yaml

# on each Docker host:
cd docker-hosts
cp .env.example .env        # set HOST_LABEL and confirm VLOGS_ENDPOINT (tailnet FQDN)
docker compose up -d
# then add the host's IP to metrics/scrapes/docker-hosts.yaml and re-apply
```

Note: cAdvisor uses host port `8080` — remap it (and the scrape target) if taken.

## Deploy order

```bash
# 1. Operator (installs CRDs) + namespace
cd operator && ./helm.sh && cd ..

# 2. Metrics: core CRs, rules, scrapes, exporters
kubectl apply -f metrics/vmsingle.yaml -f metrics/vmagent.yaml \
              -f metrics/vmalert.yaml -f metrics/vmalertmanager.yaml
kubectl apply -f metrics/rules/ -f metrics/scrapes/
kubectl apply -f metrics/exporters/node-exporter.yaml
metrics/exporters/kube-state-metrics.sh    # needs Prometheus CRDs; see the script

# 3. Logs
cd logs && ./helm.sh && cd ..

# 4. Traces
cd traces && ./helm.sh && cd ..

# 5. Grafana (create the OIDC secret first — see grafana/oidc-secret.yaml)
cd grafana && ./helm.sh && cd ..
```

## Before it works — required edits

- **OIDC secret pair.** Generate once:
  `authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72`
  - plaintext → the `grafana-oidc` Secret (create imperatively, don't commit)
  - hash → `authelia/values.yaml` grafana client `client_secret`, then `helm upgrade` Authelia.
- **Tailnet FQDN.** This scaffold assumes `grafana.tail7e769.ts.net` (your existing tailnet,
  per `seaweedfs-admin`). If the operator assigns a different name, update it in
  `grafana/values.yaml` (`root_url`) **and** the Authelia grafana `redirect_uris`.
- **Chart value names.** `logs/collector-values.yaml` and `traces/traces-values.yaml` note a
  `helm show values` check — verify the keys against the installed chart versions.
- **Pin chart + image versions** after first install (all `helm.sh` scripts note this;
  `otel-collector.yaml` pins the collector image — bump to current).

## Follow-ups

- Dashboards: the VictoriaMetrics single-node board is migrated to
  `grafana/dashboards/victoriametrics.json`; `grafana/dashboards/apply.sh` loads it via
  the Grafana sidecar. (The old `vmagent.json`/`vmalert.json` were empty dirs Docker
  auto-created, not real boards.) Add the canonical ones by dropping their JSON in
  `grafana/dashboards/` and re-running the script — vmagent (gnetId 12683),
  vmalert (14950), node-exporter (1860), cAdvisor now that those exporters exist.
- Wire real Alertmanager receivers in `metrics/vmalertmanager.yaml` (email via
  `../../apps/smtp-relay/`), replacing the ported `blackhole`.
- Once parity is confirmed, decommission the Compose stack: `../../apps/victoriametrics/`
  (`docker compose down`), and retire that folder.
- Add app instrumentation: point `OTEL_EXPORTER_OTLP_ENDPOINT` at
  `otel-collector.monitoring.svc:4317`.
