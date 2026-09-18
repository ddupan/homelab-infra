# Sandbox External Secrets Operator

本目录在 sandbox 集群部署独立的 External Secrets Operator `2.8.0`，并通过
`ClusterSecretStore/openbao` 读取 OpenBao KV v2 中共享的 OpenSandbox API key。它不复用
homelab 集群的 ESO Pod、ServiceAccount 或 Kubernetes auth backend。

OpenBao 的 `auth/kubernetes-sandbox`、对应 role、policy、sandbox API 地址与公开 CA
完全由 `infrastructure/openbao/terraform/` 管理。CA 文件提交到 Git 是刻意设计：CA
是公开信任材料，版本化后集群重建造成的 trust root 变化会产生可审计的 Terraform diff。

ESO 使用 TokenRequest 生成短期 ServiceAccount JWT。OpenBao 未配置长期
`token_reviewer_jwt`，而是使用登录 JWT 调用 sandbox TokenReview；因此
`external-secrets` ServiceAccount 仅额外绑定内建 `system:auth-delegator`。

## 部署顺序

1. 在 OpenBao 写入 OpenSandbox API key：

   ```bash
   openssl rand -hex 32 | bao kv put kv/k8s/opensandbox-api api_key=-
   ```

2. 在 `infrastructure/openbao/terraform` 执行 `terraform plan` 和 `terraform apply`，
   创建 `kubernetes-sandbox` auth mount、backend config、role 与只允许读取
   `kv/k8s/opensandbox-api` 的最小权限 policy。
3. 合并 Flux 变更。依次等待 `flux-system/external-secrets-operator`、
   `flux-system/external-secrets` Ready，再等待 `flux-system/opensandbox` 滚动完成。

operator 与配置拆成两个 Flux Kustomization，确保全新集群先安装 CRD，再声明
`ClusterSecretStore`；不要为了减少目录而把两层重新合并。

## 验收

```bash
kubectl get clustersecretstore openbao
kubectl -n opensandbox-system get externalsecret opensandbox-api-key
kubectl -n opensandbox-system get secret opensandbox-api-key
```

只检查 Secret 是否存在及 key 名，不输出 `data`。`ClusterSecretStore` 或
`ExternalSecret` 不 Ready 时，先检查 `auth/kubernetes-sandbox`，不要临时创建静态
Bao token Secret。
