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
- **独立 cache-server**：runner 镜像内 `config-pod-cache.yaml` 指向本 namespace 的
  `gitea-runner-cache` Service，所以与 homelab 同名部署一份，secret 本地生成。
- **容量按 CPU 调度**：sandbox1 为 4 CPU / 8G（宿主 pve1 的 i3 与 iam-spike-build 共用），
  sandbox2 为 8 CPU / 6G / 64G rootfs。executor 的 CPU request 等于 limit（2），调度器
  据此在 sandbox1 放 1 个、sandbox2 放 3 个，`POD_CAPACITY=4` 与之一致；超出可调度数量
  的 Pod 会 Pending 并在交接期限后失败，所以改节点规格时两者要一起调。cache 总量上限
  6GB。

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
