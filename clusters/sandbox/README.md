# Sandbox 集群

这里是 OpenSandbox、CI 和 AI Agent workload 所在双节点 k3s 集群的 Flux
reconciliation 入口。LXC、PostgreSQL、K3s、固定版本的 Flux controllers 与 root
sync 由 `infrastructure/sandbox-cluster/` 中的 Ansible 管理；本目录只组合集群内
workload。

Flux 通过 `https://git.ddupan.top/panxiao81/homelab-infra.git` 读取公开仓库。
Ansible 将 homelab CA 注入 `GitRepository/flux-system` 引用的同名 Secret，不使用
长期 Git 凭据。root Kustomization 从 `./clusters/sandbox` 开始 reconciliation，
初始保持 `prune: false`。

Root bootstrap 已完成。后续按依赖顺序分别引入：

1. 监控 CRD、kube-state-metrics 以及 kubelet/cAdvisor 抓取配置；
2. SPIRE Agent、SPIFFE CSI Driver 与 workload registration；
3. Kata Containers、`block-plain` RuntimeClass；
4. OpenSandbox controller/server；CI Pool 与 runner 调度器随后独立接入。

每一阶段单独合并并等待对应 Flux Kustomization Ready，不在 bootstrap 时一次性部署。
第一阶段监控拆为 `monitoring-operator` 与依赖它的 `monitoring`，防止 VM CR 在
VictoriaMetrics Operator CRD Ready 前进入 reconciliation。

SPIRE 阶段先由 `spire-bootstrap` 安装 CRD，并声明按上游 k8s_psat Server plugin
要求收窄的 reviewer：它可以调用 TokenReview，并只读查询用于证明的 Pod 与 Node。
Agent ServiceAccount 留给后续 HelmRelease 创建，避免两个声明方争夺同一资源。随后运行
`infrastructure/sandbox-cluster/ansible/spire-bootstrap.yml`：playbook 从 sandbox
读取 reviewer token，在内存中组成受限 kubeconfig，再通过 stdin reconcile 到 central
集群的 `spire-server/spire-external-kubeconfigs` Secret。凭据不写入仓库、日志或控制机
文件；该 Secret 准备完成后，才能启用 central external PSAT/controller-manager 和
sandbox Agent/CSI。

External controller-manager 使用独立的 `spire-controller-manager` ServiceAccount；其
RBAC 与上游 controller-manager 所需权限一致，用于读取 workload selectors、维护
SPIFFE CR status/finalizer 和 leader election。它不复用只允许 TokenReview 的 Server
reviewer。Ansible 将两份 kubeconfig 写入同一个 central Secret 的不同 key，便于 central
chart 分别绑定 `sandbox` 与 `sandbox-controller`。

Central SPIRE Server 通过内网 `spire-server.ad.ddupan.top:8081` 接收 sandbox Agent
attestation。Server 使用 external bundle publisher 持续维护 sandbox
`spire-system/spire-bundle`，Agent 不固定或复制 trust bundle。Sandbox HelmRelease
显式关闭 Server 与 OIDC Provider，只部署 Agent DaemonSet 和 SPIFFE CSI Driver；因此
不会产生第二个 trust root。

`spire-smoke` namespace、ServiceAccount 和 `sandbox-spire-smoke` ClusterSPIFFEID 只用于
普通 Pod 的 CSI 回归夹具，稳定身份为 `spiffe://ddupan.top/sandbox/smoke`。Kata guest
不能复用 node Agent 暴露的 Unix socket；virtio-fs 只能呈现 socket 路径，不能把连接
跨过 VM 边界。Kata workload 必须使用 guest 内 Agent，具体约束见
`platform/sandbox-kata/README.md`。测试 Pod 临时创建并在验收后删除，普通 Pod 的身份
声明保留。

Kata 阶段使用官方 4.1.0 `kata-deploy` chart 的短生命周期 `job` 模式，逐节点安装并
重启 K3s。只启用 `kata-clh-runtime-rs`，不创建默认 `kata` 别名；该 handler 的
`emptyDir` 固定使用 `block-plain`，为 Docker/BuildKit overlay2 与 kind 提供 guest
内块设备文件系统。详细限制与上线验收见 `platform/sandbox-kata/README.md`。

OpenSandbox 阶段固定官方源码 commit 与 umbrella chart `0.2.2`，只部署 controller、
ClusterIP server 和 CRD。server 当前仅能从集群内部访问；在 CI 调度器接入并建立
API key 的 Secret 生命周期前，显式运行于无认证 bootstrap 模式。这个临时边界和切换
步骤记录在 `platform/sandbox-opensandbox/README.md`。

## 监控边界

这里只管理 sandbox LXC 内的 Kubernetes 监控，不负责 PVE 宿主监控。LXC 与宿主共享
内核，即使 lxcfs 虚拟化了内存和 uptime，容器内 `/proc/stat` 仍是宿主 CPU 视图；
在 LXC 内运行 node_exporter 会生成混合语义并重复采集宿主指标，因此禁止部署。

Sandbox 节点与 workload 指标来自 kubelet/cAdvisor 和 kube-state-metrics；K3s 或 LXC
特有但上述接口未覆盖的指标，应使用目标明确的 collector，不以 node_exporter 补齐。
