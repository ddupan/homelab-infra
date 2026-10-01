# kata-lxc-lab

在 `pve2` 上验证 privileged LXC 内运行 k3s、Kata/QEMU，并直接使用 PVE host 的
`/dev/kvm`、`/dev/vhost-net` 与 `/dev/vhost-vsock`。这是可销毁 PoC，不承载持久数据。

Terraform 复用原 VM PoC 的 ignored credential 文件，不复制 token：

```bash
cd infrastructure/kata-lxc-lab/terraform
export SSL_CERT_FILE=/tmp/kata-lab-ddupan-ca.pem
terraform init
terraform plan \
  -var-file=../../kata-lab/terraform/credentials.auto.tfvars
terraform apply \
  -var-file=../../kata-lab/terraform/credentials.auto.tfvars
```

当前 PoC 使用 `pve2`、VMID 147、Ubuntu 24.04 LXC template 和 16 GiB
`local-lvm` rootfs。容器为 privileged，并开启 nesting、keyctl、FUSE、mknod；
Kata 所需的 KVM、vhost 与 `/dev/net/tun` 设备显式透传；另透传 `/dev/kmsg`，因为
kubelet 启动时会打开该设备。
PVE 9 的 `force_rw_sys=1` feature 用于开放 kubelet 所需的少量 `/proc/sys` 写操作；
provider 0.111.1 尚未暴露该 feature，因此同样由 `pct` 设置。

k3s/Kata worker 还使用以下 privileged LXC 原生配置；PVE 9 使用 cgroup v2，因此设备
规则采用 `lxc.cgroup2.devices.allow`：

```text
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
```

这些设置让容器内 kubelet、containerd 和 Kata shim 能管理 mount、cgroup、设备与
共享宿主 sysctl。因此外层 LXC 不是安全边界；不可信 CI 的安全边界是内层 Kata VM。
`/dev/kmsg` 当前直接透传，没有使用 `/dev/console` symlink fallback。

PVE 将 privileged LXC 的创建限制为 `root@pam`（API token 即使拥有 `PVEAdmin` 也
缺少 root-only 的 `Sys.Modify`）。因此实际创建入口使用 root SSH 上的 Ansible/pct：

```bash
cd infrastructure/kata-lxc-lab/ansible
ansible-playbook create.yml
ansible-playbook bootstrap.yml
ansible-playbook kata.yml
ansible-playbook verify.yml
ansible-playbook verify-fuse.yml
```

Terraform 文件保留用于记录 provider 权限边界与声明式目标；当前 token 执行 apply 会
在创建前返回 403，不会产生资源或 state。

## 验证结果

当前管理地址为 `192.168.10.128`：2026-09-14 主 LAN DHCP 池调整后，从 `.11`
续租迁移到 `.128`，并同步 Ansible inventory。它仍是动态租约，不是固定地址。

2026-09-14，pve2 VMID 147 / `192.168.10.11` 验证通过：

- LXC 内 k3s `v1.36.4+k3s1` node Ready；
- Kata Containers 4.1.0 `qemu-runtime-rs` 安装成功；
- Kata guest kernel `6.18.35`，外层共享的 PVE kernel `7.0.2-6-pve`；
- Kata Pod 内的 Docker 27.5.1 daemon 成功运行 `busybox:1.37` 嵌套容器；
- `/dev/net/tun` 是 Kata 创建 TAP/link 的必要设备，未透传时 runtime-rs 在
  `create link` 返回 `ENOENT`；
- `fuse-overlayfs` smoke test 成功：Docker 报告
  `storage-driver=fuse-overlayfs`，并成功运行嵌套容器。

正式方案保持 Kata 默认 `emptydir_mode = "shared-fs"`，不向 LXC 暴露 host
`/dev/loop-control` 或 `/dev/loopN`。dockerd 镜像需要包含 `fuse-overlayfs`；启动前在
Kata guest 内创建临时设备节点 `mknod /dev/fuse c 10 229`，随后强制传入
`--storage-driver=fuse-overlayfs`。该 `/dev/fuse` 属于内层 guest kernel，不是 PVE
host 设备透传，并随 Kata Pod 一起销毁。

删除三个 smoke Pod 后，LXC cgroup 统计约 505 MB anonymous memory、1.34 GB file
cache；后者主要来自刚拉取的 Kata/Docker images，可由宿主回收。也就是说常驻 worker
的不可回收 working set 约 500 MB，8 GiB 配置是 cgroup 上限而非预分配。

## Gitea ephemeral runner PoC

`runner/` 定义一次性 Gitea runner Pod。整个 Pod 使用 `runtimeClassName: kata`；
runner 通过 guest 内同 Pod 的 dockerd 创建 job container，不连接 LXC/PVE host 的
Docker socket。dockerd 使用 zot 中预先发布的 `dind-fuse:29.7.1`，其
`/var/lib/docker` 是随 Kata Pod 删除的 `emptyDir`。

runner 以 `GITEA_RUNNER_EPHEMERAL=1` 注册，只接收一个 `runs-on: kata-poc` job；接单
后 Gitea 撤销其 runner credential，job 完成后进程与 Kata VM 一起退出。当前 PoC
手动创建一个 runner 等待 `.gitea/workflows/kata-runner-smoke.yml`，尚未部署
`workflow_job` webhook controller，因此不会保留常驻空闲 runner。

注册 token 只在运行时从现有 OpenBao/ESO 消费副本投递到 PoC 集群的临时 Secret，
不写入此目录。两个 Pod image 使用 `imagePullPolicy: Never`，部署前从可信工作站将
已验证镜像导入 PoC k3s containerd；这是当前 zot 拉取仍要求 SPIFFE 身份时的
bootstrap 边界，不是正式镜像分发方案。

正式接入 zot 前需要把这个 cluster 注册到 SPIRE，并为 runner Pod 创建专用
`ClusterSPIFFEID`。届时 runner 与 dockerd sidecar 在同一路径只读挂载 CSI Workload
API socket，runner 的 `container.options` 再把该路径 bind-mount 到 job container。
zot 只对最终 SPIFFE ID 的 `panxiao81/dind-fuse` 仓库授予
`read/create/update`；禁止授予 namespace 或整个 trust domain 写权限。

2026-09-14 已完成真实 Gitea job 验收：Actions run `242` / job `445` 使用
`alpine:3.22`，10 秒成功；runner container 退出码为 `0`，原生 dockerd sidecar 随后
由 kubelet 终止，Pod 最终为 `Succeeded`，没有保留空闲 Kata VM。guest 内核为
`6.18.35`，dockerd `29.7.1` 使用 `fuse-overlayfs`。

首次尝试暴露了两个部署陷阱：`COPY` 默认保留源文件 mode，入口脚本原为 `0664`，
必须在 Dockerfile 使用 `COPY --chmod=0755`；只配置 `ephemeral-storage: 20Gi` limit
会形成同值 request，使 12 GiB PoC 节点无法调度。当前 manifest 显式 request 1 GiB、
limit 8 GiB。完整 `ubuntu-latest` job image 也不适合这个小 rootfs，基础生命周期验收
改用 Alpine；正式 worker 必须扩容本地 image/cache 空间或使用更精简的 job image。

## Cloud Hypervisor 内存记账验证

2026-09-17 在 pve2 的一次性 VMID 148 中安装 k3s v1.36.4+k3s1 与 Kata 4.1.0，
只启用 `clh-runtime-rs`，验证 Cloud Hypervisor 在 privileged LXC 内不会重现早期
microVM PoC 的 private memfd 双重记账问题。测试完成后已删除 VMID 148。

Cloud Hypervisor `/api/v1/vm.info` 报告：

```json
{"size":3254779904,"shared":true,"hugepages":false,"prefault":false,"thp":true}
```

Kata guest 在 memory-backed `emptyDir` 中写入 1 GiB 后：

- VMM `Pss_Shmem` 从约 247 MiB 增至约 1269 MiB；
- VMM `Pss_Anon` 写入前后均约 1.2 MiB；
- 外层 LXC `shmem` 增加约 1 GiB，`anon` 基本不变；
- LXC `memory.events` 的 `max`、`oom` 与 `oom_kill` 均为 0；
- 删除 Pod 后 VMM 退出，LXC `shmem` 回落到约 1.6 MiB。

因此 Kata 的 Cloud Hypervisor handler 已使用 shared memfd，等价于独立 launcher 的
`--memory shared=on` 修复；后续 OpenSandbox/Kata 方案无需为 guest RAM 预留近似双倍
的 LXC cgroup 内存。部署验收仍应检查 `vm.info.config.memory.shared=true`，防止上游
配置或 runtime handler 变化造成回归。

测试期间还发现 pve2 `local-lvm` thin pool 已达到 100%；临时 rootfs 必须放到
`pve-rg-hdd`，不能根据容器内部 `df` 的剩余空间判断 thin pool 是否可写。

## Block-backed emptyDir 与 CI 构建验证

2026-09-17 又在 pve2 的一次性 VMID 148 中验证 Kata 4.1.0
`clh-runtime-rs` 的以下 drop-in：

```toml
[runtime]
emptydir_mode = "block-plain"
```

结果如下：

- 普通 Kubernetes `emptyDir` 被创建为稀疏 `disk.img`，由 Cloud Hypervisor 直接作为
  block device 热插拔；guest 内 `/var/lib/docker` 是 `/dev/vdb` 上的 ext4。
- Docker 29.1.5 成功强制使用原生 `overlay2`，不再需要 `fuse-overlayfs`；整个过程
  没有使用 PVE host 或 LXC 的 loop device。
- `emptyDir.sizeLimit: 8Gi` 没有决定虚拟磁盘容量。由于 kubelet 所在文件系统约
  12 GiB，guest 看到的 ext4 约 11.7 GiB；这与 Kata 已知的 block-backed emptyDir
  限制一致。
- 包含 256 MiB payload、2000 个小文件和一个额外复制层的冷 BuildKit 构建耗时
  46 秒；同一 LXC、同一 DRBD HDD 存储上的 runc 对照为 34 秒，Kata 约慢 35%。
- 在 overlay2 容器层内写入并 fsync 512 MiB：Kata 为 12 秒（40.5 MB/s），runc 为
  10 秒（50.3 MB/s）；创建一万个小文件两者均约 2 秒。
- kind v0.27.0 / Kubernetes v1.32.2 首次启动失败是因为 Kata guest 内的 dockerd
  容器没有 `/dev/kmsg`，不是 block storage 或 cgroup 故障。在 privileged dockerd
  启动前执行 `mknod /dev/kmsg c 1 11` 后，kind 创建成功：总计 122 秒，进入等待阶段
  后 23 秒 control-plane Ready，随后可正常删除。
- 测试时稀疏 backing file 逻辑大小约 12 GiB，构建和 kind 后实际占用约 1.8 GiB。
  删除 Pod 后 backing file、Cloud Hypervisor 进程和 kind 容器全部消失；host/LXC
  均无 loop device 残留，LXC 没有 OOM 事件。

因此 `block-plain` 能解决 virtio-fs 不能作为 overlayfs upperdir 的问题，并满足
BuildKit 与 kind 的功能要求。正式 CI RuntimeClass 必须使用独立的 block-backed
配置，并在 dockerd bootstrap 中创建 guest `/dev/kmsg`。它仍比同机 runc 构建慢约
20–35%，且 `emptyDir.sizeLimit` 不能可靠限制虚拟磁盘容量。PoC 曾据此建议为 kubelet
目录提供独立文件系统；正式 sandbox 集群最终没有采用该设计：独立 volume 增加了
DRBD 与 LXC 挂载生命周期复杂度，却没有隔离 containerd 等其他节点数据。正式节点
改用单一、容量明确的 rootfs，并以磁盘占用监控、Pod 删除后的 backing-file 回收检查
和实际构建基准作为上线门槛。
