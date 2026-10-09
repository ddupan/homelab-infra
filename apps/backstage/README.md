# Backstage

Backstage 作为 homelab 的只读开发者门户运行。应用源码、插件、测试和镜像构建归
`panxiao81/backstage` 仓库管理；本目录只保存 Kubernetes/Flux 部署声明，并通过
OCI digest 固定镜像。

## 外部前置

- OpenBao `kv/k8s/backstage` 必须包含以下与容器环境变量同名的字段：
  `BACKEND_SECRET`、`AUTH_SESSION_SECRET`、`POSTGRES_PASSWORD`、`GITEA_TOKEN`。
  其中旧的 `AUTH_OIDC_CLIENT_ID` / `AUTH_OIDC_CLIENT_SECRET`（Authelia 客户端）不再使用：Deployment 的 `env`
  从 `backstage-sso` Secret 取值，优先于 `envFrom`。
- OpenBao `kv/k8s/techdocs-s3-reader` 提供 TechDocs 只读 S3 凭据，投射为
  `TECHDOCS_S3_ACCESS_KEY_ID` / `TECHDOCS_S3_SECRET_ACCESS_KEY`。
- PostgreSQL 需要在共享集群中预先创建由 `backstage` 角色拥有的 `backstage`
  数据库；密码必须与 OpenBao 中的 `POSTGRES_PASSWORD` 一致。
- 登录走 iam-login（`sso.ddupan.top`，`AUTH_OIDC_METADATA_URL`）。客户端由 `apps/iam-login/terraform/clients.tf`
  注册，回调 `https://backstage.lab.ddupan.top/api/auth/oidc/handler/frame`；secret 由 Terraform 写入
  `kv/k8s/backstage-sso`，经 `sso-external-secret.yaml` 同步为 `backstage-sso`。
- 入口 `backstage.lab.ddupan.top`（PowerDNS，external-dns 发布）；旧名 `backstage.ad.ddupan.top` 只做 301 跳转。

Flux 等待 ExternalSecret 和 Deployment 就绪；任何前置缺失都会使该
Kustomization 保持 NotReady，而不会回退到明文 Secret。

## 镜像更新

`panxiao81/backstage` 的 CI 在 main push 后只推送 `:latest`。
`platform/flux-image-automation` 跟踪 `latest` 背后的 digest，由 `flux-bot`
直接提交到本仓库 main，不经过 PR。main 的分支保护（Gitea 设置，不在 IaC 中）必须保留
`flux-bot` 在推送白名单里，否则推送被 pre-receive hook 拒绝，自动部署静默停止
（2026-10-04 加保护时发生过，ImageUpdateAutomation 显示 `pre-receive hook declined`）。`deployment.yaml` 中 image 行的
`$imagepolicy` 注释是 setter 标记，删除后自动更新会静默停止。

旧 digest 失去 tag 后会被 zot GC 回收（24h），因此不要把 Deployment 手工固定到
一个已不是 `latest` 的 digest 并长期保留。

## TechDocs

文档不随镜像构建。各仓库用 job id 为 `techdocs` 的 workflow 调用
`panxiao81/ci-actions/publish-techdocs`，生成后上传到 SeaweedFS bucket `techdocs`；
Backstage 以 `builder: external` 只读该 bucket。发布身份由 OpenBao role
`ci-techdocs-publisher` 统一授予，凭据在 `kv/k8s/techdocs-s3-publisher`。

## Flux 可见性

`backstage-read-only` 额外允许读取 Kustomization、Git/Helm/OCI Repository、
ImageRepository 与 ImagePolicy（get/list/watch，无写权限），供 Backstage 实体的
Kubernetes 标签页按 `backstage.io/kubernetes-id` label 展示 Flux 对象。要让某个 Flux
对象出现在实体下，给它加上与实体注解相同的 label。HelmRelease 未授权：`spec.values`
可能内联敏感配置。共享的 `flux-system` GitRepository 不打 label。
