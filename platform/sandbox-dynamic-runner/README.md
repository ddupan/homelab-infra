# Sandbox dynamic-runner worker

CI 负载一高，laptop 上的服务就跟着挂。这里在 sandbox 集群部署一个只运行
`kubernetes-worker` 的 dynamic-runner 实例，把 Pod job 分流到 sandbox。它是 pod 池
的成员 `pod-sandbox`：以自己的 Gitea runner registration（`TASK_SOURCE=gitea`）声明与
池内其他成员相同的 label，只在本地容量池有空位时 `FetchTask`。哪个成员有空位，
Gitea 就把 job 交给谁，不需要额外的调度配置（见 gitea-dynamic-runner
`docs/runner-registration-migration.md`）。

## 与 homelab worker 的差异

- **facade 是本集群的 ClusterIP**：executor 只回报给创建它的 worker，facade URL 与
  SPIFFE ID（`spiffe://ddupan.top/sandbox/ns/dynamic-runner/sa/dynamic-runner-controller`）
  都与 homelab 实例不同。一个 facade 后只能有一个实例，所以 Deployment 用 `Recreate`，
  不能加 replica；扩容是另起一个 worker。
- **capability key 独立生成**：它只把 executor 绑定到创建它的 worker，由 ESO
  Password generator 在本集群生成，不与 homelab 共享。
- **自己的 runner 凭据**：`kv/k8s/dynamic-runner-pod-sandbox`（`uuid`、`token`），由
  gitea-dynamic-runner `scripts/register-runner pod-sandbox self-hosted,pod,container,kubernetes`
  一次注册生成。sandbox ESO policy 只读这一个路径，不读 NATS 或 homelab scheduler
  的 secret；sandbox 被攻破时可在 Gitea 单独停用 `pod-sandbox`。
- **executor 身份**：parent 由 `SPIRE_CLUSTER=sandbox` 与 Pod 所在节点 UID 推导，
  ClusterStaticEntry 由 central SPIRE controller-manager 的 sandbox 集群配置处理。
- **Actions cache**：executor 的 runner 配置来自 `runner-config.yaml`（ConfigMap），cache
  存进 SeaweedFS 的 `ci-cache` bucket，与 homelab 成员共享；S3 key 由 ESO 从
  `kv/k8s/gitea-runner-cache-s3` 同步。
- **容量**：sandbox1 为 4 CPU / 8G（宿主 pve1 的 i3 与 iam-spike-build 共用），sandbox2 为
  8 CPU / 6G / 64G rootfs。executor 的 CPU request 很小，调度只受内存 request 约束
  （见 `limitrange.yaml`），实际上限是 `POD_CAPACITY=8`，由宿主 CPU 决定：接近 16 个
  executor 时两台 PVE 宿主 CPU 跑满，K3s 的数据库随之超时（2026-11-06）。
  超出可调度数量的 Pod 会 Pending 并在交接期限后失败，所以改节点规格时要一起核对。

## 上线

policy、本目录与 `clusters/sandbox/apps/dynamic-runner.yaml` 在同一次合并中上线：
Terraform CI 在 main 上 apply `sandbox-external-secrets` policy，Flux 同时部署
本目录。policy 生效前 ExternalSecret 会同步失败并由 ESO 重试，worker 在 secret
就绪后启动。等待 `flux-system/dynamic-runner` Ready。

## 验收

```bash
kubectl -n dynamic-runner get externalsecret,secret,pod
kubectl -n dynamic-runner logs deploy/dynamic-runner-controller | grep -E 'identity_bound|acked'
```

只检查 Secret 是否存在及 key 名，不输出 `data`。job 落到 sandbox 后应看到
`identity_bound`、`runner_claimed` 与 `acked`，且 executor Pod 的
ClusterStaticEntry parent 是 `.../k8s_psat/sandbox/<节点 UID>`。
