# Sandbox dynamic-runner worker

CI 负载一高，laptop 上的服务就跟着挂。这里在 sandbox 集群部署一个只运行
`kubernetes-worker` 的 dynamic-runner 实例，把 Pod job 分流到 sandbox。scheduler
仍只在 homelab（`platform/dynamic-runner/`）运行；两个 worker 共享同一个 NATS
durable consumer，各自只在本地容量池有空位时拉取 assignment，因此不需要额外的
调度配置，哪边有空位 job 就落到哪边。

## 与 homelab worker 的差异

- **facade 是本集群的 ClusterIP**：executor 只回报给创建它的 worker，facade URL 与
  SPIFFE ID（`spiffe://ddupan.top/sandbox/ns/dynamic-runner/sa/dynamic-runner-controller`）
  都与 homelab 实例不同。一个 facade 后只能有一个实例，所以 Deployment 用 `Recreate`，
  不能加 replica；扩容是另起一个 worker。
- **capability key 独立生成**：它只把 executor 绑定到创建它的 worker，由 ESO
  Password generator 在本集群生成，不与 homelab 共享。
- **共享 secret 来自 OpenBao**：NATS worker 密码（`kv/k8s/nats`）与 scheduler 的 Gitea
  runner 凭据（`kv/k8s/dynamic-runner`）。sandbox ESO 的 policy 因此能读这两个对象的
  全部字段（包括 producer 密码、webhook secret），这是有意接受的取舍。
- **executor 身份**：parent 由 `SPIRE_CLUSTER=sandbox` 与 Pod 所在节点 UID 推导，
  ClusterStaticEntry 由 central SPIRE controller-manager 的 sandbox 集群配置处理。
- **独立 cache-server**：runner 镜像内 `config-pod-cache.yaml` 指向本 namespace 的
  `gitea-runner-cache` Service，所以与 homelab 同名部署一份，secret 本地生成。
- **容量更保守**：节点是 4 CPU 的 LXC（6Gi / 4Gi 内存），根盘是 32G HDD 且与 job 的
  Docker 存储、cache PVC（local-path）共用。`POD_CAPACITY=2`，executor 默认 limit
  2 CPU / 3Gi，cache 总量上限 6GB。扩大 LXC 后再相应调高。

## 上线顺序

1. `infrastructure/openbao/terraform`：`terraform plan` 确认只改
   `sandbox-external-secrets` policy，然后 apply。
2. 合并本目录与 `clusters/sandbox/apps/dynamic-runner.yaml`，等待
   `flux-system/dynamic-runner` Ready。

## 验收

```bash
kubectl -n dynamic-runner get externalsecret,secret,pod
kubectl -n dynamic-runner logs deploy/dynamic-runner-controller | grep -E 'identity_bound|acked'
```

只检查 Secret 是否存在及 key 名，不输出 `data`。job 落到 sandbox 后应看到
`identity_bound`、`runner_claimed` 与 `acked`，且 executor Pod 的
ClusterStaticEntry parent 是 `.../k8s_psat/sandbox/<节点 UID>`。
