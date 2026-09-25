# Backstage

Backstage 作为 homelab 的只读开发者门户运行。应用源码、插件、测试和镜像构建归
`panxiao81/backstage` 仓库管理；本目录只保存 Kubernetes/Flux 部署声明，并通过
OCI digest 固定镜像。

## 外部前置

- OpenBao `kv/k8s/backstage` 必须包含以下与容器环境变量同名的字段：
  `BACKEND_SECRET`、`AUTH_SESSION_SECRET`、`AUTH_OIDC_CLIENT_ID`、
  `AUTH_OIDC_CLIENT_SECRET`、`POSTGRES_PASSWORD`、`GITEA_TOKEN`。
- PostgreSQL 需要在共享集群中预先创建由 `backstage` 角色拥有的 `backstage`
  数据库；密码必须与 OpenBao 中的 `POSTGRES_PASSWORD` 一致。
- Authelia OIDC 客户端回调地址为
  `https://backstage.ad.ddupan.top/api/auth/oidc/handler/frame`。
- AD DNS 需要将 `backstage.ad.ddupan.top` 指向 Envoy Gateway
  `192.168.10.127`。

Flux 等待 ExternalSecret 和 Deployment 就绪；任何前置缺失都会使该
Kustomization 保持 NotReady，而不会回退到明文 Secret。
