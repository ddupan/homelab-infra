# Gitea dynamic runner

本目录部署单副本 Go controller，在同一进程运行 RunnerService scheduler、原生
Kubernetes worker、OpenSandbox worker 和 SPIFFE mTLS facade：

```text
Gitea RunnerService -> scheduler -> JetStream ci.runner.container.kubernetes
                                      |
                                      v
                              homelab Kubernetes Pod
                                      |
                         SPIFFE mTLS RunnerService facade
                                      |
                                      v
                                     Gitea
```

`container+kubernetes` placement 不经过 OpenSandbox；`vm+opensandbox` placement
访问 VyOS 暴露的
OpenSandbox Lifecycle API；本目录不修改 sandbox 平台侧 ESO、Bao Terraform 或
OpenSandbox chart 所有权边界。

## Canary 安全边界

- Deployment 为单副本并使用 `Recreate`：worker 的 claim 与容量池都在进程内，滚动
  重叠时新实例会把旧实例尚未交接完的 executor 恢复成自己的而双双卡死
  （2026-10-04）。worker 退出时会删除尚未交接的 executor 并把 assignment 交回队列。
  重启间隙 facade 短暂不可用，runner 的上报会重试。scheduler 仍通过 Kubernetes
  Lease 保持单 leader。
- scheduler 使用一个 runner registration，并按总容量启动并发 `FetchTask` goroutine；
  `POD_CAPACITY=4` 与 `VM_CAPACITY=1` 分别限制本实例两个 backend admission pool。
  worker 只在池有空位时从共享 durable consumer 拉取 assignment，池满时 assignment
  保持 JetStream pending、留给其他 worker；任一 backend 不占用另一方的执行槽位，
  也不会创建超出容量的 workload。
- executor 身份的 SPIRE parent 由 `SPIRE_CLUSTER` 与 Pod 所在节点 UID 推导，
  controller 因此需要 `nodes get`。
- controller 重启后通过 backend metadata 恢复已被认领的 executor 的 claim 并继续
  服务 facade。
- executor 镜像使用 digest；Pod 以 UID 2000 运行，SPIRE `ClusterStaticEntry` 同时绑定
  具体 Pod UID 与 `unix:uid:2000`。
- facade 通过仅内网可路由的 `192.168.10.127:30443` NodePort 提供给 sandbox executor；
  双方使用 Workload API X509-SVID mTLS，并按 SPIFFE ID 而不是 IP/DNS 名验证服务端。
  该入口不经过公网或 Cloudflare Tunnel。
- controller 的 SPIFFE ID 固定为
  `spiffe://ddupan.top/ns/dynamic-runner/sa/dynamic-runner-controller`。
- NATS 保留既有最小权限分离：`ci-producer` 仅 publish，`ci-worker` 仅 pull/ACK。

facade claim registry 在启动时从 Pod/OpenSandbox metadata 恢复；scheduler leadership
由 Kubernetes Lease 持久化协调。Deployment 仍保持 `replicas: 1`，滚动更新期间允许
一个额外 Pod 提供 facade 连续性。

## Secret 边界

`ExternalSecret/dynamic-runner` 从既有 `ClusterSecretStore/openbao` 读取：

- `kv/k8s/nats`：producer/worker 密码；
- `kv/k8s/opensandbox-api:api_key`：保留给后续 VM worker；
- `kv/k8s/gitea-runner:token`：保留的 runner registration token；
- `kv/k8s/dynamic-runner`：scheduler UUID/token、facade HMAC key 和回滚所需 webhook secret。

scheduler credential 由官方 Gitea Runner v3.5.0 一次注册生成；它只挂载到 controller，
不会进入 executor。facade capability key 至少 32 字节，controller 为每个 assignment
确定性生成独立 capability。不要打印 Secret、创建静态 Bao token或把 credential 写入
Git。OpenBao 写入使用本机 SPIFFE JWT 换取的短期 `local-development` token。

## Workflow 身份与依赖配置

workflow 可复用 [`panxiao81/ci-actions`](https://git.ddupan.top/panxiao81/ci-actions)
中的 `spiffe-openbao-login@v1` 和 `setup-nexus@v1`。这不改变 runner 的权限边界：
runner 仅提供 Node.js 20、`spire-agent` 与 Workload API socket，workflow 负责声明 Bao
role、audience 和具体用途，目标服务 policy 决定是否授权。短期 Bao token 会进入
Actions job 临时文件，因此这些 Action 只允许在本目录管理的一次性 Pod/VM executor
中使用，不能迁移到共享或持久 runner。

匿名读取 Nexus public repository 只需 `setup-nexus@v1`，不应为了依赖下载额外申请
Bao 凭据；需要发布制品时再为对应 repository 建立独立 service account 与最小权限
policy。

## 首次验收

合并后先观察 Flux 与 controller，不要立即开启 VM：

```bash
flux reconcile kustomization dynamic-runner --with-source
kubectl -n dynamic-runner wait externalsecret/dynamic-runner \
  --for=condition=Ready --timeout=2m
kubectl -n dynamic-runner rollout status deploy/dynamic-runner-controller --timeout=5m
kubectl -n dynamic-runner logs deploy/dynamic-runner-controller -f
```

确认 scheduler 只领取一条 `[self-hosted,container,kubernetes]` task，然后验证：

1. assignment message 进入并离开 durable `container.kubernetes` consumer；
2. `gitea-task-<task-id>` Pod 创建，取得实际 Pod UID；
3. 同名 `ClusterStaticEntry` 的 parent ID 包含该 UID，SPIFFE ID 使用 repository/job key；
4. 官方 runner v3.5.0 经 facade claim 精确 task，Gitea 实时收到日志和终态；
5. Pod consumer 达到 capacity 时 VM consumer 仍可独立接受任务。

Pod 与 VM 都在 Gitea 接受终态后先把 terminal marker 写入各自 backend metadata，再由
lifecycle reconciler 删除执行器。首次 VM 测试仍须观察 BatchSandbox、Pod 与
ClusterStaticEntry 全部消失；完整自动清理通过前不得提高 `POD_CAPACITY` 或
`VM_CAPACITY`。

VM backend 已通过 `vm-dev` canary 完成 Docker、kind、SPIFFE 和完整生命周期测试。
生产规范标签为 `[self-hosted, vm, opensandbox]`，旧 `[self-hosted, vm]` 仍严格映射到
同一 placement。初始保持 `VM_CAPACITY=1`；扩容前先观察实际任务的
资源水位、等待时间以及 OpenSandbox 是否存在 terminal sandbox 残留。

## 回滚

若 controller 在领取 task 前失败，回滚到前一 commit 的 Python controller/Pod worker
manifests。若已经创建 `gitea-task-*` Pod，先保留现场并核对 Gitea task 状态，不能直接
重启 scheduler 造成重复执行。scheduler registration 和 capability key 保留在 Bao，
回滚不需要删除或打印它们。
