# Sandbox 集群

这里是 OpenSandbox、CI 和 AI Agent workload 所在双节点 k3s 集群的 Flux
reconciliation 入口。LXC、PostgreSQL、K3s、固定版本的 Flux controllers 与 root
sync 由 `infrastructure/sandbox-cluster/` 中的 Ansible 管理；本目录只组合集群内
workload。

Flux 通过 `https://git.ddupan.top/panxiao81/homelab-infra.git` 读取公开仓库。
Ansible 将 homelab CA 注入 `GitRepository/flux-system` 引用的同名 Secret，不使用
长期 Git 凭据。root Kustomization 从 `./clusters/sandbox` 开始 reconciliation，
初始保持 `prune: false`。

当前 root 为空，作为 bootstrap canary。后续按依赖顺序分别引入：

1. 监控 CRD、VictoriaMetrics 抓取配置和节点 exporter；
2. SPIRE Agent、SPIFFE CSI Driver 与 workload registration；
3. Kata Containers、`block-plain` RuntimeClass；
4. OpenSandbox operator/server 及 `ci-pod`、`ci-vm` Pools。

每一阶段单独合并并等待对应 Flux Kustomization Ready，不在 bootstrap 时一次性部署。
