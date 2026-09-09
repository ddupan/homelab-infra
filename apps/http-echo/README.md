# HTTP Echo（Flux GitOps canary）

这是 Flux 首个低风险工作负载，用于验证 PR 合并后的自动部署、健康检查和漂移修复。
Flux 将它部署到独立的 `gitops-canary` namespace。

| 文件 | 说明 |
| --- | --- |
| `deployment.yaml` | 两个 `hashicorp/http-echo` 副本。 |
| `service.yaml` | 只在集群内可达的 ClusterIP Service。 |
| `kustomization.yaml` | Flux 实际构建入口，只包含 Deployment 和 Service。 |
| `httproute.yaml` | 保留的历史 Contour 示例，**不在 Kustomization 中，不会部署**。 |

## 验证

合并 canary PR 后不手动 apply。等待 Flux 自动创建资源：

```bash
sudo k3s kubectl -n flux-system get kustomization http-echo
sudo k3s kubectl -n gitops-canary get deployment,service,pod
```

初始 `prune: false`。验证自动部署后，可以手动把 Deployment replicas 改成 1，
确认 Flux 恢复为 Git 中的 2。删除行为应使用单独的无业务 ConfigMap 和 PR 测试，
验证完成前不得为此路径启用 prune。
