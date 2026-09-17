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

1. 监控 CRD、kube-state-metrics 以及 kubelet/cAdvisor 抓取配置；
2. SPIRE Agent、SPIFFE CSI Driver 与 workload registration；
3. Kata Containers、`block-plain` RuntimeClass；
4. OpenSandbox operator/server 及 `ci-pod`、`ci-vm` Pools。

每一阶段单独合并并等待对应 Flux Kustomization Ready，不在 bootstrap 时一次性部署。

## 监控边界

这里只管理 sandbox LXC 内的 Kubernetes 监控，不负责 PVE 宿主监控。LXC 与宿主共享
内核，即使 lxcfs 虚拟化了内存和 uptime，容器内 `/proc/stat` 仍是宿主 CPU 视图；
在 LXC 内运行 node_exporter 会生成混合语义并重复采集宿主指标，因此禁止部署。

Sandbox 节点与 workload 指标来自 kubelet/cAdvisor 和 kube-state-metrics；K3s 或 LXC
特有但上述接口未覆盖的指标，应使用目标明确的 collector，不以 node_exporter 补齐。
