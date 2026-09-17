# Sandbox Kata Containers

本目录通过 Flux 安装 Kata Containers 4.1.0，只启用 Cloud Hypervisor 的 Rust
runtime，并创建明确命名的 `kata-clh-runtime-rs` RuntimeClass。OpenSandbox 的 VM
Pool 必须显式选择该 RuntimeClass；不创建含义不明确的 `kata` 默认别名。
OCI chart 同时固定到已验证的 4.1.0 artifact digest，升级时必须重新执行本页验收。

安装使用官方 `kata-deploy` chart 的 `job` 模式。每次 install/upgrade 由 dispatcher
逐个节点创建短生命周期、可修改 host 的安装 Job，写入 Kata artifacts 和 K3s containerd
配置并重启对应节点的 K3s；节点恢复 Ready 后才继续下一节点。安装结束后不保留拥有
host 写权限的 DaemonSet。新增节点后必须触发 HelmRelease upgrade，使 dispatcher
重新枚举节点。

`clh-runtime-rs` 固定使用：

```toml
[runtime]
emptydir_mode = "block-plain"
```

因此普通 `emptyDir` 会在 kubelet volume 目录创建稀疏 backing file，并作为块设备
热插拔给 guest。Docker/BuildKit 可以在 guest ext4 上使用原生 overlay2，避免
virtio-fs 作为 overlayfs upperdir 时的限制。Kata 当前不会用
`emptyDir.sizeLimit` 决定该虚拟盘容量；实际容量取决于节点 rootfs。节点磁盘占用、
Pod 删除后的 backing-file/VMM 回收和真实构建基准必须作为上线验收项目。

`kata-monitor` 常驻每个节点，只读访问 K3s containerd socket 与 Kata sandbox 状态，
由 `VMPodScrape` 写入中央 VictoriaMetrics。它不拥有 Kubernetes API 凭据或 host 写
权限。

## 上线验收

Flux reconciliation 完成后至少确认：

1. 两个节点重新回到 Ready，`RuntimeClass/kata-clh-runtime-rs` 存在；
2. Kata Pod 内核与 LXC host 内核不同，且 `/dev/kvm` 可用；
3. Cloud Hypervisor API 的 `vm.info.config.memory.shared` 为 `true`；
4. `spire-smoke` ServiceAccount 的 Kata Pod 可获得
   `spiffe://ddupan.top/sandbox/smoke`，错误 ServiceAccount 无法获得身份；
5. block-backed `emptyDir` 上 Docker 使用 `overlay2`，BuildKit 与 kind smoke test
   通过；kind 的 dockerd bootstrap 需要先在 guest 内执行
   `mknod /dev/kmsg c 1 11`；
6. 删除测试 Pod 后，Cloud Hypervisor 进程、backing file 和临时数据全部回收，且
   LXC 没有新增 OOM 事件；
7. 中央 VictoriaMetrics 中两个 `kata-monitor` target 均为 `up=1`。

不要依赖手工修改 `/opt/kata` 或 K3s containerd 配置；任何修复都必须回写 chart
values 并由 Flux reconciliation。
