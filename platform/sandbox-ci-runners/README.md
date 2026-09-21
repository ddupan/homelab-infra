# OpenSandbox Gitea runner Pools

本目录只部署零预热的 `ci-vm` Pool、sandbox 内的 SPIFFE identity controller，以及仅供
内网 VyOS 转发的 OpenSandbox NodePort。`ci-vm` 使用 `kata-clh-runtime-rs`，每个 VM
执行单一任务并在结束后删除。普通 Pod job 直接运行在 homelab，不进入 OpenSandbox。

Pool 中 task-executor 接收 Lifecycle API 下发的进程环境。guest-local SPIRE Agent 用
Pod-bound PSAT 向中央 SPIRE 注册；identity controller 从 BatchSandbox allocation
取得真实 Pod UID，再创建精确的 `ClusterStaticEntry`。runner 只有拿到请求中的完整
repository/task SVID 后才领取一次性 Gitea registration token。

这些 `ClusterStaticEntry` 位于 sandbox 集群，由 central SPIRE Server 内的
`spire-controller-manager-sandbox` 通过受限 external kubeconfig reconcile。必须在
`platform/spire/values.yaml` 显式启用 external controller-manager 的
`reconcile.clusterStaticEntries`（chart 默认关闭）；仅看到 CR 存在但没有 status，不算
身份链路就绪。

## 部署依赖

- OpenSandbox chart 和 CRD 已 Ready；
- RuntimeClass `kata-clh-runtime-rs` 已存在；
- 中央 SPIRE 已发布 `ConfigMap/opensandbox/spire-bundle-pem`；
- VyOS `10.60.0.13:8080` 转发 sandbox1/2 的 NodePort `30080`；
- runner/controller 镜像均使用 Zot digest，而不是可变 tag。

本目录不读取 OpenBao，也不修改 OpenSandbox 平台侧 ExternalSecret、ClusterSecretStore
或 Bao policy。OpenSandbox API key 只存在于平台 server Secret 和 homelab controller
Secret，两边由各自身份读取同一 Bao 资源。

## 上线验收

先确认 Secret 和 API 认证，命令不得输出 key：

```bash
kubectl -n dynamic-runner wait externalsecret/dynamic-runner --for=condition=Ready --timeout=2m
kubectl -n dynamic-runner exec deploy/dynamic-runner-controller -- \
  wget -qO- http://10.60.0.13:8080/health
```

然后触发一个 `runs-on: [self-hosted, vm]` 的最小 workflow，并同时观察：

```bash
kubectl -n dynamic-runner logs deploy/dynamic-runner-controller -f
kubectl -n opensandbox get pool,batchsandbox,pod -w
kubectl get clusterstaticentry -l app.kubernetes.io/component=opensandbox-identity -w
kubectl -n opensandbox logs deploy/opensandbox-identity -f
```

合格证据必须同时包含：

1. Lifecycle create 成功并选择 `ci-vm`；
2. 分配 Pod 的 `runtimeClassName` 为 `kata-clh-runtime-rs`；
3. entry 的 parent ID 包含该 Pod 的 UID，SPIFFE ID 使用 repository/task；
4. Gitea 显示临时 runner 带 `self-hosted,vm` labels 并完成真实任务；
5. 任务后 BatchSandbox、Pod、ClusterStaticEntry 和临时 runner 均消失。

清理超时对象时只调用 Lifecycle DELETE，不直接删除 Pool Pod。若 controller 已不可用，
可从 OpenSandbox API 按 metadata 定位 sandbox 后执行 DELETE；不要绕过 API 伪造状态。

## 故障定位

- `401`：检查 homelab ExternalSecret Ready 和文件挂载，不打印 Secret；
- `PoolCapacityExhausted`：检查 `ci-vm` 的 `poolMax` 及残留 BatchSandbox；
- runner 等待 SVID：核对 allocation Pod UID、ClusterStaticEntry parentID、guest Agent 日志；
- runner 等待 token：核对 `192.168.10.127:8787` 的 sandbox 到 homelab 路由；
- Docker 任务失败：检查 `docker` sidecar 和 `/run/docker/docker.sock` 的 group 2000。
- kind node 的 systemd 报 `Failed to create /init.scope` 或 `Structure needs
  cleaning`：确认 `docker` sidecar 通过 `dockerd-entrypoint.sh` 启动。直接执行
  `dockerd` 会绕过官方 DinD cgroup v2 nesting 初始化，使子容器的私有 cgroup
  namespace 根变成 `threaded`，systemd 无法创建 domain cgroup。
- kind 的 kubeadm 卡在 `CreateContainer`，而 nested containerd goroutine 停在
  `bbolt` 的 `fdatasync`：不要直接把 Kata shared mount 用作 Docker 数据目录。
  `ci-vm` 在 guest 内创建稀疏 ext4 镜像并 loop-mount 到 `/var/lib/docker`；该镜像
  随 Sandbox 删除，不得在节点侧遗留。临时启动安装 `e2fsprogs` 仅用于首次集成
  验证，验证后应固化到自有 DinD 镜像。
