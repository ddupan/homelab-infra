# Sandbox 集群

该目录管理供 OpenSandbox、CI 和 AI Agent workload 使用的独立双节点 k3s 集群。
基础设施和节点生命周期由 Ansible 管理；Kubernetes API 可用后，集群内组件由
`clusters/sandbox/` 下的 Flux desired state 管理。

## 所有权边界

Ansible 管理以下持久状态：

- pve1/pve2 上的 privileged LXC、磁盘、固定网络与 KVM/vhost/TUN/kmsg 设备；
- LXC OS 基线、内部 CA、外部 PostgreSQL 与 K3s；
- 固定版本的 Flux controllers 和 root sync bootstrap；
- 只读状态验证和数据库切换 runbook。

Flux 管理以下 Kubernetes 资源：

- Kata Containers 和 CI 专用的 `block-plain` RuntimeClass；
- SPIRE Agent、SPIFFE CSI Driver 与 workload identity 声明；
- vmagent、kube-state-metrics、kubelet/cAdvisor scrape 配置和告警；
- OpenSandbox operator/server、`ci-pod` 与 `ci-vm` Pools。

同一个对象只能有一个 owner。Ansible 不直接部署上述集群内 workload；Flux 不管理
LXC、K3s datastore 或 K3s 本身。

监控范围仅覆盖 sandbox LXC 内的 Kubernetes 与 workload。不得在 LXC 内部署
node_exporter：LXC 的 `/proc` 是 lxcfs 虚拟视图与宿主内核视图的混合，尤其
`/proc/stat` 会重复暴露 PVE 宿主 CPU 数据。PVE 自身的 node_exporter 或其他宿主
监控不属于本目录；sandbox 使用 kubelet/cAdvisor 和 kube-state-metrics。

## 声明拓扑

| 对象 | PVE 节点 | VMID | 地址 | 资源 |
|---|---:|---:|---|---|
| `sandbox1` | pve1 | 148 | `10.60.0.11/24` | 4 vCPU / 6 GiB / 2 GiB swap |
| `sandbox2` | pve2 | 149 | `10.60.0.12/24` | 4 vCPU / 4 GiB / 2 GiB swap |
| K3s API VIP | VyOS | — | `10.60.0.13:6443` | HAProxy TCP LB |

节点与 API VIP 均位于现有 PVE `labnet`（VLAN 100，`10.60.0.0/24`），通过
VyOS `10.60.0.1` 路由；不为 sandbox 新建 VNet，也不占用 `192.168.10.0/24`
地址。需要从 LAN 访问的服务统一经 VyOS 路由或 LB 暴露。两个 LXC 均使用
`pve-rg-hdd` 上的 32 GiB rootfs；不为 `/var/lib/kubelet` 单独创建 volume。Kata
`block-plain` 产生的数据随 Pod 生命周期清理，当前规模没有额外磁盘故障域的需求。
K3s API 的 `10.60.0.13/32` 由 VyOS 现有 labnet interface 持有，HAProxy 以 TCP
健康检查把 `6443` 分发到两个 control-plane 节点；它与 PostgreSQL 主从切换逻辑无关。
LXC 内通过 `/etc/tmpfiles.d/kmsg.conf` 持久维护 `/dev/kmsg -> /dev/console`；否则
kubelet 会因 LXC 不提供真实 host `/dev/kmsg` 而反复退出。
每个 LXC 还以只读 bind mount 使用宿主的 `/lib/modules`。LXC 与 PVE 宿主共享内核，
guest 若看不到对应版本的模块目录，K3s 无法加载 `br_netfilter` 和 `overlay`，Flannel
也不会生成节点的 subnet 配置。

## PostgreSQL 写入口与切换

K3s 使用外部 PostgreSQL，首期采用 primary + synchronous standby。VyOS 在 labnet
gateway `10.60.0.1:5432` 提供固定 TCP 入口，backend 只包含当前声明的 primary；
不把普通 TCP 或 PostgreSQL 存活检查等同于“节点可写”，也不自动把流量切到 standby。
VyOS 2025.11 的 PostgreSQL protocol check 会生成缺少必需 `user` 参数的 HAProxy
配置，因此这里只使用基础 TCP check；真正的可写性由 `verify.yml` 通过 SQL 验证。

数据库切换必须由 Ansible runbook 受控完成：先隔离旧 primary，再提升 standby，最后
更新 VyOS backend。首期不部署 PgBouncer、Patroni、repmgr 或额外 DCS，也不宣称两节点
PostgreSQL 能够自动 HA。以后具备第三个仲裁节点时再重新评估自动 failover。

数据库凭据位于 Bao `kv/infra/sandbox-postgresql`，包含 K3s 登录密码和 physical
replication 密码。运行 Ansible 前由本机 SPIFFE identity 获取短期 Bao token，再把
两个值注入 `SANDBOX_K3S_DB_PASSWORD` 与 `SANDBOX_REPLICATION_PASSWORD`；凭据不写入
inventory、Git 或 Ansible fact cache。首次创建 standby 只允许覆盖不含任何业务库的
Ubuntu 默认空集群，之后重复执行不会 reseed。

## Ansible

安装固定依赖：

```bash
cd infrastructure/sandbox-cluster/ansible
uv venv .venv
uv pip install --python .venv/bin/python -r requirements.txt
source .venv/bin/activate
ansible-galaxy collection install -r requirements.yml
export PVE_API_PYTHON="$PWD/.venv/bin/python"
```

部署入口最终为：

```bash
ansible-playbook site.yml
```

只安装或 reconcile K3s（LXC、OS baseline 和 PostgreSQL 已就绪时）：

```bash
ansible-playbook k3s.yml
```

K3s 外部 datastore URI 由运行时 `SANDBOX_K3S_DB_PASSWORD` 生成，密码在 URI 中
进行 URL 编码，最终仅持久化于节点 root 可读的 `/etc/rancher/k3s/config.yaml`
（mode `0600`）。首节点生成的 K3s join token 仅在同一次 Ansible run 内传给第二节点；
不在 inventory 或 Git 中维护副本。首期关闭内建 Traefik 和 ServiceLB。

部署后使用同一组运行时凭据执行只读验收：

```bash
ansible-playbook verify.yml
```

当前已经声明 LXC 生命周期、最小 OS baseline、PostgreSQL 和 K3s，包括系统级
homelab CA trust。Flux `v2.9.5` controllers 与 root sync 也由 Ansible 通过 K3s
server manifests 管理；root 使用 homelab CA 访问公开 Gitea 仓库，不保存 Git token。
集群内 workload 由 `clusters/sandbox/` 分阶段纳入 Flux。

## 已验证的 Kata CI 前置条件

- Cloud Hypervisor 必须报告 `vm.info.config.memory.shared=true`；
- CI RuntimeClass 必须使用 `[runtime] emptydir_mode = "block-plain"`；
- dockerd bootstrap 在 guest 内创建 `/dev/kmsg`：`mknod /dev/kmsg c 1 11`；
- `/var/lib/docker` 必须是 guest block device 上的 ext4，Docker driver 必须为
  `overlay2`，不能静默退化到 `vfs` 或 `fuse-overlayfs`；
- Pod 删除后必须不存在遗留 `disk.img`、VMM 或临时 credential。

PoC 的完整数据和陷阱见 `../kata-lxc-lab/README.md`。
