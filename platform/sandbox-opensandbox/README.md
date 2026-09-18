# Sandbox OpenSandbox

本目录在独立 sandbox k3s 集群部署 OpenSandbox controller、server 与 CRD。Flux 从
上游 commit `8f01e935c2cabba778cf37a152033fae062fa0f4` 构建官方 umbrella chart
`0.2.2`；该源码渲染结果已与 release `opensandbox-0.2.2.tgz` 对比一致。不要改为跟随
浮动 branch 或 tag。

server 只提供集群内 `opensandbox-server.opensandbox-system.svc:80` ClusterIP，不部署
Gateway、Ingress 或 LoadBalancer。sandbox workload 位于 `opensandbox` namespace，
默认使用 `kata-clh-runtime-rs`；CI Pool、runner 镜像、动态 SPIFFE registration 均由
runner 项目后续声明，本目录不预制。

## API 认证

`ExternalSecret/opensandbox-api-key` 从 OpenBao
`kv/k8s/opensandbox-api:api_key` 投影同名 Secret。这个路径不归属于某个 Kubernetes
集群：sandbox server 与 homelab runner 调度器分别通过自己的 Bao 身份读取。server 只通过
`secretKeyRef` 读取：

```yaml
- name: OPENSANDBOX_SERVER_API_KEY
  valueFrom:
    secretKeyRef:
      name: opensandbox-api-key
      key: api-key
```

仓库与 Helm values 均不保存 API key。OpenSandbox 不支持更丰富的原生 workload
authentication；runner 后续读取同一 Bao 路径并在请求头中使用 API key。
`opensandbox-values` 带 Flux watch label，values 变化会立即触发 Helm reconcile，不依赖
30 分钟的 HelmRelease interval。

## 验收

合并后等待 `flux-system/opensandbox` 与 `opensandbox-system/opensandbox` Ready，并确认：

```bash
kubectl get crd batchsandboxes.sandbox.opensandbox.io pools.sandbox.opensandbox.io
kubectl -n opensandbox-system get deploy,pod,svc
kubectl get runtimeclass kata-clh-runtime-rs
```

控制面上线不创建 CI Pool，也不产生 sandbox workload。首个 runner 集成应另行提交 Pool
与完整的 Lifecycle API smoke test。
