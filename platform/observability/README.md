# observability

Metrics, logs, and traces for the cluster — one VictoriaMetrics-ecosystem stack,
operator-driven, running in the `monitoring` namespace. Replaces the standalone
Docker Compose monitoring stack. The retired stack and its three Docker data volumes
were removed on 2026-09-16 with the maintainer's explicit approval.

监控覆盖缺口与补齐路线图见 [COVERAGE.md](COVERAGE.md)。

## Grafana 当前入口（2026-10-09）

统一使用 <https://grafana.lab.ddupan.top>（PowerDNS，external-dns 发布），由共享 Envoy Gateway 的
`https-lab` listener 与 `*.lab.ddupan.top` 证书提供 TLS。旧名 `grafana.ad.ddupan.top` 只做 301 跳转：
OAuth state cookie 按主机名，两个名字不能混用。
Grafana root_url 和 iam-login（sso.ddupan.top）回调均使用此域名；旧专用 Tailscale Ingress 已停用。
远程客户端仍需有到 LAN 的路由及已配置的内网 DNS 转发。

内存看板：`/d/homelab-memory`；采集配置及 AppArmor 规则见
[主机与进程内存采集](metrics/exporters/README.md)。

Grafana 由 Flux 管理；修改 values 后通过 Git 合并触发 HelmRelease，避免现场 Helm
修改被漂移检测回滚。Authelia 当前不由 Flux 管理，需单独 Helm upgrade 并先结构比较
live values。迁移时先添加 DNS 和回调，再切换 Grafana。Recreate 策略会短暂中断访问，
但保留原 PVC、用户、看板和数据源。回滚需同时恢复 root_url、回调和 Ingress 配置。

## 初始部署记录（2026-07-10）

Live and verified in the `monitoring` namespace (operator chart 0.66.2):
metrics (data queryable), logs (pods ingesting), traces (VTSingle CRD, verified via
Jaeger API), Grafana (3 datasources healthy, VM dashboard loaded, Tailscale ingress
`grafana.tail7e769.ts.net`, Authelia OIDC client registered). All PVCs on
`localpv-zfs-ceph`. Note the vmagent hot-reload RBAC fix (`metrics/reload-rbac.yaml`,
see `metrics/README-reload.md`) and that VL/VT CRDs are served under `.../v1`.

### Flux 接管状态

可观测性栈使用一个 `observability` Flux Kustomization，按依赖顺序逐步加入 Operator、
Metrics、Logs、Traces 和 Grafana，避免多个 reconciler 争夺共享 namespace、Helm source
或 VictoriaMetrics CRD。brownfield 迁移期间保持 `prune: false`。

VictoriaMetrics Operator 已固定 chart `0.66.2` / app `v0.73.1` 完成分阶段 Flux
HelmRelease 接管，保存 values 与 `operator/values.yaml` 一致。阶段一确认 Helm revision
保持为 2、Operator Pod UID 未变、24 个 CRD 及 6 个核心 VM/VL/VT CR 未变化；随后
通过独立 PR 解除暂停。

其余已部署资源也已统一完成接管：Metrics CR、rules、scrapes、node-exporter，Logs 的
VLSingle 与固定 `0.3.6` 的 Collector，以及 Traces 的 VTSingle、OTel Collector，最后是
固定 `10.5.15` 的 Grafana 与 dashboard ConfigMap。阶段一确认 11 个 Pod UID、4 个 PVC、
6 个核心 CR、17 个 rule/scrape 对象及 dashboard 哈希均未变化，Collector 和 Grafana
Helm revision 均保持为 1；随后在同一独立 PR 中解除两个 HelmRelease 的暂停。

首次 Grafana Helm reconcile 暴露了本地 ZFS RWO 卷限制：chart 默认 `RollingUpdate`
会先创建新 Pod，但 CSI 拒绝在旧 Pod 仍挂载 PVC 时再次 mount，使 upgrade 卡在
`pending-upgrade`。`grafana/values.yaml` 因此显式使用 `deploymentStrategy.type: Recreate`。
Grafana 升级会有一次短暂停机，但旧 Pod 会先退出，新 Pod 才挂载同一 PVC；不要改回
RollingUpdate，除非存储改为真正支持并发挂载的 RWX。

以下内容明确不属于本批接管：尚未部署的 kube-state-metrics、`vlogs-ingress.yaml`，以及
仅作 standalone chart 参考的 `traces-values.yaml`。Grafana 的 OIDC 客户端
由 `apps/iam-login/terraform` 注册，secret 写入 bao `kv/k8s/grafana-sso`，经
`grafana/sso-external-secret.yaml` 同步为 `grafana-sso` Secret。

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

VictoriaMetrics Operator 的 Prometheus converter 已启用；官方
`prometheus-operator-crds` chart 由 `operator/` 一并管理。因此应用 chart 可以原生
声明 `ServiceMonitor`、`PodMonitor` 或 `PrometheusRule`，再由 converter 转换为对应
VM 资源，不需要每个应用额外维护一份 `VM*Scrape`。

## CRD 约定

**新增抓取与告警一律用上游 prometheus-operator CRD**：`ServiceMonitor`、`PodMonitor`、`Probe`、
`ScrapeConfig`、`PrometheusRule`。VM operator 的 converter 把它们转换成对应的 `VM*` 对象
（v0.73.1 起五种都支持，2026-10-09 实测）。不要直接写 `VMServiceScrape` / `VMPodScrape` /
`VMStaticScrape` / `VMProbe` / `VMRule`——那样配置就绑死在 VM 上，也和应用 chart 自带的 Monitor 两套写法。

| 需求 | 用 |
|---|---|
| 集群内 Service 后面的端点 | `ServiceMonitor` |
| 集群内 Pod（没有 Service 或端口未声明） | `PodMonitor`（`portNumber`） |
| 集群外固定地址 | `ScrapeConfig`（`staticConfigs`） |
| blackbox 探测 | `Probe` |
| 规则 | `PrometheusRule` |

已知的坑（都是实测出来的）：

- **converter 会丢掉 `ScrapeConfig.jobName`**（转换后为 null，job 变成默认值）。用 `relabelings` 的
  `targetLabel: job` 设定。`Probe.jobName` 正常保留。
- **converter 不删除转换出来的对象**（`VM_ENABLEDPROMETHEUSCONVERTEROWNERREFERENCES=false`），而本
  Kustomization 又是 `prune: false`。把一个 `VM*` 对象换成上游 CRD 时：同名同类（`VMProbe` →
  `Probe`、`VMServiceScrape` → `ServiceMonitor`）会被 converter 原地接管；**换了类型的**
  （`VMStaticScrape` → `ScrapeConfig` 变成 `VMScrapeConfig`）旧对象会留在集群里重复抓取，合并后要
  手工 `kubectl delete`。
- **`PodMonitor.portNumber` 只匹配已声明的容器端口**：operator 生成
  `keep __meta_kubernetes_pod_container_port_number=<n>`，容器没声明端口就永远没有 target，而且不报错。
  这种情况不指定端口，用 relabelings 把 `__address__` 改成 `<podIP>:<port>`（见 cloudflared）。
- 目标标签不要和指标自带的标签同名（如 LINSTOR 指标自带 `node`），否则会被覆盖、原值改名为 `exported_*`。

2026-10 之前留下的 `VMNodeScrape`（kubelet / cadvisor / node-exporter）与若干 `VMStaticScrape`
（docker-hosts、shared-*）尚未迁移。

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
    rules/                  VMRules migrated from the retired Compose stack (source in Git history)
    exporters/              node-exporter (+VMNodeScrape), kube-state-metrics (Helm)
    scrapes/               kubelet + cAdvisor VMNodeScrapes
  logs/                     VLSingle CR + victoria-logs-collector (Helm)
  traces/                   victoria-traces-single (Helm) + OTel Collector
  grafana/                  Grafana (Helm) values, OIDC secret, install script
  docker-hosts/             per-Docker-host sidecar (cAdvisor + node-exporter + Vector)
```

## Docker hosts

The Compose services on Docker hosts (`../../apps/vlmcsd`, `../../apps/ps3netsrv`, `../../apps/netboot`, ...)
are monitored too:

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

# 5. Grafana (OIDC client + secret: apps/iam-login/terraform, synced by ESO)
cd grafana && ./helm.sh && cd ..
```

## Before it works — required edits

- **OIDC client.** `homelab_oidc_client.grafana` in `apps/iam-login/terraform/clients.tf`; its secret
  reaches Grafana via bao and ESO (`grafana-sso`). Nothing to create by hand.
- **Tailnet FQDN.** This scaffold assumes `grafana.tail7e769.ts.net` (your existing tailnet,
  per `seaweedfs-admin`). If the operator assigns a different name, update it in
  `grafana/values.yaml` (`root_url`) **and** the client's `redirect_uris` in `apps/iam-login/terraform/clients.tf`.
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
- 旧 Compose 监控栈已于 2026-09-16 按维护者要求清理：原先已无容器，本次移除
  旧配置及 `victoriametrics_vmdata`、`victoriametrics_vmagentdata`、
  `victoriametrics_grafanadata` 三个无引用 Docker 卷。没有创建备份或迁移旧数据，
  Kubernetes 监控资源未修改。旧配置仍可从 Git 历史查阅，旧卷中的数据已删除。
- Add app instrumentation: point `OTEL_EXPORTER_OTLP_ENDPOINT` at
  `otel-collector.monitoring.svc:4317`.
