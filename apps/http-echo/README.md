# HTTP Echo（Flux GitOps canary）

这是 Flux 首个低风险工作负载，用于验证 PR 合并后的自动部署、健康检查和漂移修复。
Flux 将它部署到独立的 `gitops-canary` namespace。

| 文件 | 说明 |
| --- | --- |
| `deployment.yaml` | 两个 `hashicorp/http-echo` 副本。 |
| `service.yaml` | 只在集群内可达的 ClusterIP Service。 |
| `kustomization.yaml` | Flux 实际构建入口；明确排除历史 HTTPRoute。 |
| `httproute.yaml` | 保留的历史 Contour 示例，**不在 Kustomization 中，不会部署**。 |

## 验证

合并 canary PR 后不手动 apply。等待 Flux 自动创建资源：

```bash
sudo k3s kubectl -n flux-system get kustomization http-echo
sudo k3s kubectl -n gitops-canary get deployment,service,pod
```

Deployment 漂移修复已经验证：手动把 replicas 改成 1 后，Flux 能按 Git 恢复为
2。删除验证使用无业务依赖的 `flux-prune-canary` ConfigMap：第一阶段已经在
`prune: false` 时创建并确认进入 Flux inventory；本阶段从 Git 删除该对象，并仅为
`http-echo` Kustomization 开启 `prune: true`。root Kustomization 仍保持
`prune: false`，brownfield 资源不会进入此次删除范围。
