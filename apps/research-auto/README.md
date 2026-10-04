# research-auto

应用代码在 GitHub [panxiao81/research-auto](https://github.com/panxiao81/research-auto)；
该仓库于 `07b2869` 移除了 k8s 清单，部署声明自 2026-10-04 起由本目录经 Flux 管理
（`clusters/homelab/apps/research-auto.yaml`）。接管时清单与线上 `kubectl diff` 无差异。

- **镜像**：`api-deployment.yaml` / `worker-deployment.yaml` 中的 `ghcr.io/panxiao81/research-auto:sha-*`。
  升级改这里并提交；直接 `kubectl apply` 或 `kubectl set image` 会被 Flux 改回。
- **凭据**：ESO 从 Bao `kv/k8s/research-auto`、`kv/k8s/research-auto-bootstrap` 同步（`external-secret.yaml`）。
  `AWS_*` 是 SeaweedFS 专用 `research-auto` 身份（只能访问 `research` bucket），目前与
  `kv/k8s/seaweedfs-s3` 中的同名身份是两份副本。`DATABASE_URL` 指向旧 CNPG `shared-db`，随应用迁移再改。
- **break-glass**：Bao 不可用时，按 `secrets.example.yaml` 填写 gitignored 的 `secrets.yaml` 后手工 apply；
  Bao 恢复后 ESO 会覆盖回去。
- API 通过 Tailscale `LoadBalancer` 暴露（`service.yaml`）。
