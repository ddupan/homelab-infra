# Sandbox OpenSandbox

本目录在独立 sandbox k3s 集群部署 OpenSandbox controller、server 与 CRD。Flux 从
上游 release tag 构建官方 umbrella chart（见下方版本）。不要改为跟随 branch 或 rc tag。

**版本：OpenSandbox `release-1.2.1`**（tag 指向 `db708c218771a8d311356f0e96552c15df6e097a`），chart 在
`manifests/charts/opensandbox`。上游从 1.1.0 起所有组件（server、chart、execd/egress 镜像、SDK）共用一个平台版本；
GitRepository 跟随正式 `release-x.y.z` tag，不跟 rc。`values.yaml` 的 server `configToml` 必须显式写 execd 与
egress 镜像，`renovate.json` 用同一个 depName 让它们与 tag 在同一个 PR 里一起升级。

历史：0.2.2 时期钉 commit `8f01e93`。上游 2026-09-16 把 chart 挪到 `manifests/charts/`（#1857），2026-11-02 起
Renovate 把 commit pin 升过了这次重构，HelmRelease 连续 11 天无法收敛（当时 sandbox 没有 Flux 告警），由此
迁移到 1.x 并改为跟 release tag。

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
