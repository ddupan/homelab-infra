# Gitea dynamic runner

本目录部署单副本 Go controller，在同一进程运行原生 Kubernetes worker、OpenSandbox
worker 和 SPIFFE mTLS facade。两个 worker 各自是一个 Gitea runner 池的成员
（`TASK_SOURCE=gitea`）。每个池只声明一个 label，job 的 `runs-on` 也只写这一个：
sandbox 的 `pod-sandbox` 是 `[self-hosted]`（迁移期间另带别名 `pod`），`pod-laptop` 是
`[self-hosted-large]`，`vm` 是 `[self-hosted-vm]`，云端是 `[cloud]`/`[cloud-small]`
（见 gitea-dynamic-runner `docs/design-principles.md`）。每个成员只在本地容量池有空位时用自己的 registration
`FetchTask`，Gitea 在池内分发：

```text
Gitea ──FetchTask(pod-laptop)──▶ homelab executor Pod ─┐
      ──FetchTask(vm)─────────▶ OpenSandbox VM ────────┤
                                                       ▼
                                 SPIFFE mTLS RunnerService facade ──▶ Gitea
```

注册：gitea-dynamic-runner `scripts/register-runner`，凭据位于
`kv/k8s/dynamic-runner-pod-laptop` 与 `kv/k8s/dynamic-runner-vm`。原先的 scheduler、
NATS 队列与 Lease 已在 2026-10-05 移除（见 gitea-dynamic-runner
`docs/runner-registration-migration.md`）。

`container+kubernetes` placement 不经过 OpenSandbox；`vm+opensandbox` placement
访问 VyOS 暴露的
OpenSandbox Lifecycle API；本目录不修改 sandbox 平台侧 ESO、Bao Terraform 或
OpenSandbox chart 所有权边界。

## Canary 安全边界

- Deployment 为单副本并使用 `Recreate`：worker 的 claim 与容量池都在进程内，不能
  有两个实例同时持有同一个 registration。worker 退出时删除尚未交接完的 executor，
  并把这些 task 报为失败供 rerun（Gitea 不能收回已领取的 task）。重启间隙 facade
  短暂不可用，runner 的上报会重试。
- `POD_CAPACITY=4` 与 `VM_CAPACITY=1` 分别限制两个 backend admission pool；满载时
  worker 不领取，task 在 Gitea 显示为等待，由池内其他成员领取。任一 backend 不占用
  另一方的执行槽位，也不会创建超出容量的 workload。
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

facade claim registry 在启动时从 Pod/OpenSandbox metadata 恢复。Deployment 为
`replicas: 1` 加 `Recreate`：同一个 registration 与 facade 不能同时由两个实例持有。

## Secret 边界

`ExternalSecret/dynamic-runner` 从既有 `ClusterSecretStore/openbao` 读取：

- `kv/k8s/dynamic-runner-pod-laptop`、`kv/k8s/dynamic-runner-vm`：两个池成员各自的
  runner registration（`uuid`、`token`）；
- `kv/k8s/dynamic-runner:facade_capability_key`：facade HMAC key；
- `kv/k8s/opensandbox-api:api_key`：vm 成员调用 OpenSandbox Lifecycle API。

registration 由 gitea-dynamic-runner `scripts/register-runner` 以官方 Gitea Runner
v3.5.0 一次注册生成（registration token 留在 `kv/k8s/gitea-runner`，不挂载给
controller）；它只挂载到 controller，不会进入 executor。facade capability key 至少
32 字节，controller 为每个 assignment 确定性生成独立 capability。不要打印 Secret、创建静态 Bao token或把 credential 写入
Git。OpenBao 写入使用本机 SPIFFE JWT 换取的短期 `local-development` token。

## 云端池（cloud-scheduler）

`runs-on: [cloud]` 的 job 由 `cloud-scheduler` 为每个排队 job 注册一个 ephemeral runner，
并在 GKE Autopilot（`infrastructure/gcp-ci/terraform`）创建一次性 Pod，Pod 直连 Gitea。
设计见 gitea-dynamic-runner `docs/cloud-executor.md`。

- GKE 访问：SPIRE JWT-SVID（`aud=gcp`）经联邦换成 `dynamic-runner-controller` GCP 服务账号，
  没有密钥。API 地址在 Deployment，CA 在 `gke-ci.yaml`（公开数据，集群重建时更新）。
- runner 注册在 admin 层（`CLOUD_GITEA_SCOPE=admin`），和 `pod-laptop`、`vm` 一样对整个实例生效。
- `kv/k8s/dynamic-runner:cloud_gitea_token`：Gitea API token（`write:admin`），用于列出 job、
  注册和删除 runner。它必须先写入 Bao，否则 ExternalSecret 失败。
- 云端 Pod 的 runner 配置、cache Secret 和 namespace 由 `gcp-ci` 的 Terraform 创建。
- 规格（`CLOUD_RESOURCE_PROFILES`）：默认 2 vCPU / 4 GiB；`runs-on: [cloud-small]` 是
  0.5 vCPU / 1 GiB，给 security-scan 这类轻量 job，能和默认规格的 job 挤在同一个节点上。
  试用账号的 GCE 配额（全局 12 vCPU、SSD 250 GB）是实际的并发上限。
- 停用：从 `COMPONENTS` 去掉 `cloud-scheduler`；剩下的 runner 在 Gitea 里删除即可。

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

Gitea runner 列表中 `pod-laptop`、`vm` 应在线，然后验证：

1. 日志依次出现 `received`、`capacity_acquired`、`identity_bound`、`runner_claimed`；
2. `gitea-task-<task-id>` Pod 创建，同名 `ClusterStaticEntry` 的 parent 是 Pod 所在节点
   的 agent（`.../k8s_psat/homelab/<节点 UID>`），SPIFFE ID 使用 repository/job key；
3. 官方 runner v3.5.0 经 facade claim 精确 task，Gitea 实时收到日志和终态；
4. pod 池满载时 task 在 Gitea 显示为等待，vm 池仍可独立领取。

Pod 与 VM 都在 Gitea 接受终态后先把 terminal marker 写入各自 backend metadata，再由
lifecycle reconciler 删除执行器。首次 VM 测试仍须观察 BatchSandbox、Pod 与
ClusterStaticEntry 全部消失；完整自动清理通过前不得提高 `POD_CAPACITY` 或
`VM_CAPACITY`。

VM backend 已通过 `vm-dev` canary 完成 Docker、kind、SPIFFE 和完整生命周期测试。
生产标签为 `[self-hosted-vm]`。初始保持 `VM_CAPACITY=1`；扩容前先观察实际任务的
资源水位、等待时间以及 OpenSandbox 是否存在 terminal sandbox 残留。

## 回滚

回滚到前一个 controller digest 即可；registration 与 capability key 保留在 Bao，不需要
删除或打印。controller 重启时会把尚未交接完的 task 报为失败，已认领的 executor 由新
实例从 backend metadata 恢复。要让某个成员停止接活，在 Gitea 停用其 runner 或把
对应 worker 从 `COMPONENTS` 移除。
