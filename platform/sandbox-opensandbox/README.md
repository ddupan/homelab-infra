# Sandbox OpenSandbox

本目录在独立 sandbox k3s 集群部署 OpenSandbox controller、server 与 CRD。Flux 从
上游 commit `8f01e935c2cabba778cf37a152033fae062fa0f4` 构建官方 umbrella chart
`0.2.2`；该源码渲染结果已与 release `opensandbox-0.2.2.tgz` 对比一致。不要改为跟随
浮动 branch 或 tag。

server 只提供集群内 `opensandbox-server.opensandbox-system.svc:80` ClusterIP，不部署
Gateway、Ingress 或 LoadBalancer。sandbox workload 位于 `opensandbox` namespace，
默认使用 `kata-clh-runtime-rs`；CI Pool、runner 镜像、动态 SPIFFE registration 均由
runner 项目后续声明，本目录不预制。

## 临时认证边界

当前尚无 sandbox 集群内的 Secret 分发链路。为避免把长期凭据提交到 Git，server 暂时
通过 `OPENSANDBOX_INSECURE_SERVER=YES` 显式确认无认证模式；其网络边界严格保持为
ClusterIP。这不是最终认证方案。

runner 接入前必须先创建 `opensandbox-api-key` Secret，并把 Helm values 中的环境变量
改为：

```yaml
- name: OPENSANDBOX_SERVER_API_KEY
  valueFrom:
    secretKeyRef:
      name: opensandbox-api-key
      key: api-key
```

随后删除 `OPENSANDBOX_INSECURE_SERVER`。Secret 必须由 OpenBao/SPIFFE 派生的自动化
链路或 Ansible 注入，不得把明文写入仓库。

## 验收

合并后等待 `flux-system/opensandbox` 与 `opensandbox-system/opensandbox` Ready，并确认：

```bash
kubectl get crd batchsandboxes.sandbox.opensandbox.io pools.sandbox.opensandbox.io
kubectl -n opensandbox-system get deploy,pod,svc
kubectl get runtimeclass kata-clh-runtime-rs
```

控制面上线不创建 CI Pool，也不产生 sandbox workload。首个 runner 集成应另行提交 Pool
与完整的 Lifecycle API smoke test。
