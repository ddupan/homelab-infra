# Sandbox 监控

该目录只采集 sandbox Kubernetes 与 workload 指标：

- kubelet 与 cAdvisor；
- kube-state-metrics；
- vmagent 自身运行状态。

不得在 sandbox LXC 内部署 node_exporter。LXC 的 `/proc/stat` 暴露 PVE 宿主 CPU
视图，会产生重复且语义混合的指标。PVE 宿主监控不属于本目录。

vmagent 为所有远端样本增加 `cluster=sandbox`，并通过仅允许
`POST /api/v1/write` 的 `metrics-write.ad.ddupan.top` 路由写入 homelab VMSingle。
Operator 与 workload 拆成两个 Flux Kustomization，确保 VM CRD Ready 后再创建
VMAgent、VMNodeScrape 和 VMServiceScrape。
