# research-auto

应用代码在 GitHub [panxiao81/research-auto](https://github.com/panxiao81/research-auto)；
该仓库于 `07b2869` 移除了 k8s 清单，部署声明自 2026-10-04 起由本目录经 Flux 管理
（`clusters/homelab/apps/research-auto.yaml`）。接管时清单与线上 `kubectl diff` 无差异。

- **镜像**：`api-deployment.yaml` / `worker-deployment.yaml` 中的 `ghcr.io/panxiao81/research-auto:sha-*`。
  升级改这里并提交；直接 `kubectl apply` 或 `kubectl set image` 会被 Flux 改回。
- **凭据**：ESO 从 Bao `kv/k8s/research-auto` 同步（`external-secret.yaml`）。
  `AWS_*` 是 SeaweedFS 专用 `research-auto` 身份（只能访问 `research` bucket），目前与
  `kv/k8s/seaweedfs-s3` 中的同名身份是两份副本。
- **数据库**：pg-prod 上的 `research_auto`（Ayatori 租户，`clusters/ayatori-prod/research-auto.yaml`），
  凭据经 `database.yaml` 同步为 `research-auto-pgprod`。应用经连接池 6432；initContainer 的 yoyo 迁移
  以租户角色直连 5432（不再用 superuser）。2026-10-13 自 CNPG `postgres` 库迁入（只迁自己的 18 张表）。
- **break-glass**：Bao 不可用时，按 `secrets.example.yaml` 填写 gitignored 的 `secrets.yaml` 后手工 apply；
  Bao 恢复后 ESO 会覆盖回去。
- API 通过 Tailscale `LoadBalancer` 暴露（`service.yaml`）。
