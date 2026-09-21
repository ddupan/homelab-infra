# Gitea dynamic runner

本目录部署单副本 Go controller，在同一进程运行 RunnerService scheduler、原生
Kubernetes Pod worker、OpenSandbox VM worker 和 SPIFFE mTLS facade：

```text
Gitea RunnerService -> scheduler -> JetStream ci.runner.pod
                                      |
                                      v
                              homelab Kubernetes Pod
                                      |
                         SPIFFE mTLS RunnerService facade
                                      |
                                      v
                                     Gitea
```

Pod backend 不经过 OpenSandbox。VM backend 后续启用时才访问 VyOS 暴露的
OpenSandbox Lifecycle API；本目录不修改 sandbox 平台侧 ESO、Bao Terraform 或
OpenSandbox chart 所有权边界。

## Canary 安全边界

- Deployment 为单副本，滚动策略固定 `maxSurge: 1`、`maxUnavailable: 0`，保证新
  facade Ready 后才终止旧实例。scheduler 必须通过 Kubernetes Lease 保持单 leader，
  不能依赖 Recreate 避免重复领取。
- controller 的 single-flight gate 只允许一个已领取 task 运行；Gitea 接受终态
  `UpdateTask` 后才领取下一条。`POD_CAPACITY=1` 同时限制 worker 创建并发。
- rollout 重叠期间只有持有 `Lease/dynamic-runner-scheduler` 的 controller 执行
  `FetchTask`；所有 Ready 实例都可通过 backend metadata 恢复 claim 并服务 facade。
- executor 镜像使用 digest；Pod 以 UID 2000 运行，SPIRE `ClusterStaticEntry` 同时绑定
  具体 Pod UID 与 `unix:uid:2000`。
- facade 只有 ClusterIP，executor 通过
  `dynamic-runner-controller.dynamic-runner.svc:8443` 访问；双方使用 Workload API
  X509-SVID mTLS，不再保留公网 webhook/token endpoint。
- controller 的 SPIFFE ID 固定为
  `spiffe://ddupan.top/ns/dynamic-runner/sa/dynamic-runner-controller`。
- NATS 保留既有最小权限分离：`ci-producer` 仅 publish，`ci-worker` 仅 pull/ACK。

当前 facade claim registry 与 single-flight gate 是进程内状态。异常重启时应先检查
现存 assignment Pod 和 Gitea task，再人工决定是否恢复 scheduler；不能通过扩大副本数
规避。完成 backend-driven recovery 前保持 `replicas: 1`。

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

确认 scheduler 只领取一条 `[self-hosted,pod]` task，然后验证：

1. assignment message 进入并离开 durable `pod` consumer；
2. `gitea-task-<task-id>` Pod 创建，取得实际 Pod UID；
3. 同名 `ClusterStaticEntry` 的 parent ID 包含该 UID，SPIFFE ID 使用 repository/job key；
4. 官方 runner v3.5.0 经 facade claim 精确 task，Gitea 实时收到日志和终态；
5. terminal gate 释放后才领取下一条任务。

Pod 与 VM 都在 Gitea 接受终态后先把 terminal marker 写入各自 backend metadata，再由
lifecycle reconciler 删除执行器。首次 VM 测试仍须观察 BatchSandbox、Pod 与
ClusterStaticEntry 全部消失；完整自动清理通过前不得提高 `POD_CAPACITY`、`VM_CAPACITY`
或 scheduler single-flight 并发。

## 回滚

若 controller 在领取 task 前失败，回滚到前一 commit 的 Python controller/Pod worker
manifests。若已经创建 `gitea-task-*` Pod，先保留现场并核对 Gitea task 状态，不能直接
重启 scheduler 造成重复执行。scheduler registration 和 capability key 保留在 Bao，
回滚不需要删除或打印它们。
