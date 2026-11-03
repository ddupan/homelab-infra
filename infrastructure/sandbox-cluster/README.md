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
- sandbox External Secrets Operator、OpenSandbox controller/server；CI Pool 与 runner
  调度器由 runner 项目接入。

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
| K3s API 入口 | Ayatori LoadBalancer | — | `sandbox-k8s.lab.ddupan.top:6443` | `clusters/ayatori-prod/sandbox-k8s.yaml` |

节点与 API VIP 均位于现有 PVE `labnet`（VLAN 100，`10.60.0.0/24`），通过
VyOS `10.60.0.1` 路由；不为 sandbox 新建 VNet，也不占用 `192.168.10.0/24`
地址。需要从 LAN 访问的服务统一经 VyOS 路由或 LB 暴露。两个 LXC 的 rootfs 均在
`pve-rg-local`（本节点 SSD 单副本）；不为 `/var/lib/kubelet` 单独创建 volume。Kata
`block-plain` 产生的数据随 Pod 生命周期清理，当前规模没有额外磁盘故障域的需求。
K3s API（6443）与 OpenSandbox API（8080）经 Ayatori LoadBalancer `sandbox/k8s` 暴露，TCP 健康检查
分发到两个 control-plane 节点。客户端一律用 `sandbox-k8s.lab.ddupan.top`，它是指向 LB Hostname
`k8s.sandbox.lb.lab.ddupan.top` 的 CNAME；证书 SAN 只含这个名字，VIP 变化不影响客户端。
LXC 内通过 `/etc/tmpfiles.d/kmsg.conf` 持久维护 `/dev/kmsg -> /dev/console`；否则
kubelet 会因 LXC 不提供真实 host `/dev/kmsg` 而反复退出。
每个 LXC 还以只读 bind mount 使用宿主的 `/lib/modules`。LXC 与 PVE 宿主共享内核，
guest 若看不到对应版本的模块目录，K3s 无法加载 `br_netfilter` 和 `overlay`，Flannel
也不会生成节点的 subnet 配置。

## PostgreSQL 写入口与切换

K3s 使用外部 PostgreSQL（sandbox1、sandbox2 各一个成员），由 Patroni 自动选主。
DCS 是共享三成员 etcd（`infrastructure/etcd`），账号 `patroni-pg-sandbox` 只能读写
`/homelab/patroni/pg-sandbox/`；两节点本身没有仲裁，第三票来自 etcd。

固定入口是 Ayatori LoadBalancer `sandbox/postgresql`（`clusters/ayatori-prod/sandbox-postgresql.yaml`），
K3s 经 `pg-sandbox.lab.ddupan.top`（指向 LB Hostname 的 CNAME）连接。backend 含两个成员，
以 Patroni REST `GET :8008/primary` 做健康检查，只有 leader 返回 200。切换后 K3s
重连即到新主，无需改配置。REST 的写操作（switchover、restart）只接受成员自身地址。

- 同步复制非 strict：standby 健康时同步，掉线时自动降为异步，单节点停机不阻塞写入。
- `failsafe_mode`：etcd 不可达但两成员互通时，leader 保持可写，不因 DCS 故障降级。
- 不用 pg_rewind（需要网络 superuser）；分叉的旧主由 Patroni 从 leader 重新克隆，
  数据小且可重建。
- 断开的成员保留的 slot WAL 上限 2 GiB，不会撑满 rootfs。

数据库凭据位于 Bao `kv/infra/sandbox-postgresql`，包含 K3s 登录密码和 physical
replication 密码，运行 Ansible 前注入 `SANDBOX_K3S_DB_PASSWORD` 与
`SANDBOX_REPLICATION_PASSWORD`。Patroni 角色还需要 `BAO_TOKEN`（Bao role
`homelab-sandbox-postgresql`，由 `infrastructure/etcd/terraform` 管理）：在控制端签发
etcd 客户端证书并读取 etcd 账号，token 不下发节点。

etcd 强制 mTLS，客户端证书 60 天有效。`controller.yml` 在 laptop 安装
`homelab-sandbox-renew.timer`，每日以 SPIFFE 身份换 15 分钟 token 执行
`renew-etcd-cert.yml`，剩余不足 14 天时续签并 HUP Patroni。与 prod 的
`homelab-postgresql-renew` 分开，互不影响。

### 从手动主从接管（一次性）

已运行的 `postgresql@16-main` 不会被默认接管，role 会失败并提示。维护窗口内：

1. `infrastructure/etcd`：`terraform apply`（新增客户端 SAN 与 Bao role），再执行
   `consumers.yml` 创建 etcd 账号与 Bao 秘密。
2. 本目录 `ansible-playbook postgresql.yml -e sandbox_patroni_takeover=true`。play
   串行，先 sandbox1（现主库，取得 leader key），后 sandbox2（Patroni 拒绝在没有
   leader 时接管一个 standby）。K3s 写入中断约为 sandbox1 上 PostgreSQL 停止到
   Patroni 拉起的几秒。
3. 两个成员都在 Patroni 下以后，再跑 `infrastructure/proxmox` 的 VyOS play，把入口
   改为跟随 `/primary`；顺序反过来入口会因为健康检查全失败而中断。
4. `ansible-playbook verify.yml`，然后 `ansible-playbook controller.yml` 安装续签 timer。

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

只 reconcile Flux controllers 与 root sync manifest（不触碰 LXC、PostgreSQL 或
K3s lifecycle）：

```bash
ansible-playbook flux.yml
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
集群内 workload 由 `clusters/sandbox/` 分阶段纳入 Flux。root Kustomization 的健康检查
timeout 为 40 分钟，用于覆盖 Kata 等首次安装时会逐节点重启 K3s 的子
Kustomization；各子项仍保留自己的更短 timeout，故障会在对应子项先行暴露。

## SPIRE 跨集群 bootstrap

Sandbox 复用 homelab 的 SPIRE Server 与 `ddupan.top` trust domain。Flux 首先安装
SPIRE CRD，并创建供 k8s_psat 使用的 reviewer。它按上游 Server chart 的权限模型调用
TokenReview，并以 `get/list` 读取用于证明的 Pod 与 Node；不具有修改 workload 的权限。
在该 Kustomization Ready 后运行：

```bash
cd infrastructure/sandbox-cluster/ansible
ansible-playbook spire-bootstrap.yml
```

Playbook 不把 reviewer token 或生成的 kubeconfig 落盘，而是将目标 Secret manifest
通过 stdin 交给本机 homelab `k3s kubectl`。目标 Secret
`spire-server/spire-external-kubeconfigs` 由 Ansible 单独拥有；Flux 和人工操作不得写入。
第二次运行必须为零变更。

Secret 的 `sandbox` key 仅供 SPIRE Server 的 external PSAT plugin 验证 token 与对应的
Pod/Node；
`sandbox-controller` key 供 external controller-manager 读取 Pod/Node、reconcile SPIFFE
CR 及执行 leader election。两者使用不同 ServiceAccount，不得合并权限或互换。

## 已验证的 Kata CI 前置条件

- Cloud Hypervisor 必须报告 `vm.info.config.memory.shared=true`；
- CI RuntimeClass 必须使用 `[runtime] emptydir_mode = "block-plain"`；
- dockerd bootstrap 在 guest 内创建 `/dev/kmsg`：`mknod /dev/kmsg c 1 11`；
- `/var/lib/docker` 必须是 guest block device 上的 ext4，Docker driver 必须为
  `overlay2`，不能静默退化到 `vfs` 或 `fuse-overlayfs`；
- Pod 删除后必须不存在遗留 `disk.img`、VMM 或临时 credential。

PoC 的完整数据和陷阱见 `../kata-lxc-lab/README.md`。
