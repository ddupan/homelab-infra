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

## Guest 内 SPIFFE 身份

Kata guest 不能直接使用 node SPIRE Agent 的 CSI socket。Unix socket 的路径即使通过
virtio-fs 出现在 guest 中，连接也不能跨 VM 边界。CI Pod 应以 native sidecar 在同一
guest 内启动临时 SPIRE Agent，并满足以下约束：

1. 外层 Pod 挂载 `audience=spire-server` 的 Pod-bound projected ServiceAccount token；
2. 内层 Agent 使用 `k8s_psat` 向中央 Server attestation，Server cluster profile 必须
   启用 `use_pod_uid_for_agent_id`，使 Agent ID 包含 Pod UID；
3. 调度器为该具体 Agent 创建 registration entry；SPIFFE ID 使用仓库和任务名等稳定的
   业务语义，Pod UID 只作为 parent binding，不进入业务身份；
4. Agent 与 workload 通过 guest 内 `emptyDir` 上的 Unix socket 通信；Pod 必须设置
   `shareProcessNamespace: true`，否则 `unix` workload attestor 无法从共享 `/proc`
   解析客户端的 `SO_PEERCRED` PID；
5. 调度器必须在 registration entry 已同步到 Agent 后才放行 workload。Pod 删除后同步
   删除 entry，并 evict 对应的临时 Agent 记录。

2026-09-17 的 live PoC 已验证：以 Pod UID 作为 parent 的临时 Agent 成功注册，
`unix:uid:2000` workload 从 guest-local socket 获得
`spiffe://ddupan.top/ci/poc/task/build` X.509-SVID，Pod 正常退出。PoC 资源随后全部清理，
中央 SPIRE 恢复声明式配置。

SPIRE 1.15.3 已支持 `use_pod_uid_for_agent_id`，但当前使用的 hardened chart 0.30.2
尚未把它暴露到 values/template。正式部署应先给 chart 补齐该字段并向上游提交，随后
采用包含修复的 release；不得把手工修改 Server ConfigMap 作为运行方案。

## 上线验收

Flux reconciliation 完成后至少确认：

1. 两个节点重新回到 Ready，`RuntimeClass/kata-clh-runtime-rs` 存在；
2. Kata Pod 内核与 LXC host 内核不同，且 `/dev/kvm` 可用；
3. Cloud Hypervisor API 的 `vm.info.config.memory.shared` 为 `true`；
4. Kata Pod 内层 Agent 的 ID 包含该 Pod UID；只有调度器创建的业务 entry 所匹配的
   workload UID 能从 guest-local socket 获得预期 SPIFFE ID；
5. block-backed `emptyDir` 上 Docker 使用 `overlay2`，BuildKit 与 kind smoke test
   通过；kind 的 dockerd bootstrap 需要先在 guest 内执行
   `mknod /dev/kmsg c 1 11`；
6. 删除测试 Pod 后，Cloud Hypervisor 进程、backing file 和临时数据全部回收，且
   LXC 没有新增 OOM 事件；
7. 中央 VictoriaMetrics 中两个 `kata-monitor` target 均为 `up=1`。

不要依赖手工修改 `/opt/kata` 或 K3s containerd 配置；任何修复都必须回写 chart
values 并由 Flux reconciliation。
