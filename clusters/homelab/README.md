# Homelab 集群

这里是单节点 k3s 集群的 Flux reconciliation 入口。集群当前运行 Kubernetes
`v1.36.4+k3s1`，Flux 固定为 `v2.9.5`。

## 首次 bootstrap

仓库经过 PR 审查并合并后，在本机从合并后的 `main` 执行：

```bash
sudo k3s kubectl apply -f clusters/homelab/flux-system/gotk-components.yaml
sudo k3s kubectl apply -f clusters/homelab/flux-system/gotk-sync.yaml
```

`GitRepository/flux-system` 通过集群内 Gitea Service 读取公开仓库，不需要长期
管理员 token，也不依赖 Cloudflare、公网 DNS 或 Envoy Gateway。Gitea 暂时不可用
时，已经应用的资源继续运行，Flux 在 Gitea 恢复后重新同步。

root Kustomization 从 `./clusters/homelab` 开始 reconciliation。初始设置
`prune: false`；在逐项审计现有资源和 field ownership 之前不得开启全局 prune。

计划中的 reconciliation 顺序：

1. namespaces 和 CRD；
2. platform controllers；
3. secret references 和 storage；
4. applications。

首次部署后的最低验证：

```bash
sudo k3s kubectl -n flux-system get pods
sudo k3s kubectl -n flux-system get gitrepositories,kustomizations
```

四个 controller、GitRepository 和 root Kustomization 都必须为 Ready，随后才能
通过单独 PR 引入低风险 canary workload。

## 当前状态

- Flux `v2.9.5`、GitRepository 和 root Kustomization 均为 Ready；
- `http-echo` canary 已验证 merge 后自动部署和 replicas 漂移修复；
- `http-echo` 的专用测试 ConfigMap 已在 `prune: true` 生效后重新纳管，并由下一
  revision 自动删除；
- `http-echo` 保持 `prune: true`，root 保持 `prune: false`；
- `gitea-actions`、`gitea` 与 External Secrets 已由 Flux HelmRelease 接管，Gitea 已升级到 `1.27.3`；
- cert-manager 已固定现有 `v1.21.0` 并完成分阶段 Flux HelmRelease 接管；
- Envoy Gateway 已固定现有 `v1.5.6` 并完成分阶段 Flux HelmRelease 接管；
- OpenEBS 已进入分阶段接管：固定现有 `4.4.0`，HelmRelease 暂停等待存储基线验证；
- External Secrets Operator 已固定 chart `2.8.0` 并完成分阶段接管；
- root Kustomization 与所有 brownfield 子 Kustomization 继续保持 `prune: false`。
