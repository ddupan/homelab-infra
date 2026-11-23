# Nexus Repository POC

本目录声明一个 Nexus Repository Community Edition POC，用来验证一次性 CI runner 通过
网络服务复用 Ansible Galaxy、Go Modules 与 OCI/BuildKit 缓存。Nexus 固定为 `3.96.1`，
镜像固定到官方 multi-arch index digest；LAN 入口为
`https://nexus.lab.ddupan.top`（旧名 `nexus.ad.ddupan.top` 仍由同一 HTTPRoute 服务，新配置一律用 lab 名）。

## POC 边界

- 单副本 Deployment，`Recreate` 更新，避免一个 RWO 卷被两个 Pod 同时挂载。
- `/nexus-data` 使用 `localpv-zfs-ceph` 上的 50 GiB RWO PVC。
- 资源预算为 250m/2 GiB request、2 CPU/4 GiB limit；JVM heap 上限 2 GiB。
- 使用容器默认的 embedded H2。它只用于 POC；正式接管 OCI 制品前必须迁移到外部
  PostgreSQL，并验证备份恢复。
- 入口只在 LAN wildcard Gateway 上发布，不创建公网 DNS 或 Cloudflare route。
- 前面不加任何登录代理；它会破坏 Go、Ansible 与 OCI 非浏览器客户端。
- 现有 zot 保持不变。Nexus 完成 OCI、BuildKit cache 和恢复验收前不得迁移或删除 zot。

Terraform 管理全部 repository（含 OCI）、匿名权限、realm 与 AD 登录。不得在 UI 中创建
无人管理的长期 repository 或手工开关 realm：`security_realms` 是整份替换，UI 里启用而
HCL 里没有的 realm 会在下一次 apply 被关掉。

## 部署

Flux 从 `clusters/homelab/apps/nexus.yaml` 协调本目录，并依赖 Envoy Gateway 与 OpenEBS。
合并前只渲染配置，不直接 apply：

```bash
kubectl kustomize apps/nexus
```

合并并由 Flux 部署后检查：

```bash
kubectl -n flux-system get kustomization nexus
kubectl -n nexus get pod,pvc,service,httproute
kubectl -n nexus logs deployment/nexus --tail=100
```

启动可能需要数分钟，startup probe 允许最多十分钟。不要因初次启动较慢反复删除 Pod；
先确认 PVC 已 Bound、Pod 没有 OOM，以及日志仍在推进。

DNS 期望状态已加入 `infrastructure/samba-ad/ansible/group_vars/all/dns.yml`，需从 Samba AD Ansible root 以
`--check --diff` 核对后再按其 README 应用 DNS tag。没有 DNS 时可先用 port-forward
验证应用，但不能据此宣称 Gateway 路径已通过。

## 首次初始化与 Terraform

初始管理员密码生成在 PVC 的 `/nexus-data/admin.password`。只在交互式终端中读取并立即
完成首次密码轮换；不得把密码复制进 shell tracing、工单、Git 或命令参数。随后将
Terraform 管理账号的密码存入 OpenBao **`kv/infra/terraform/nexus` 的 `nexus_password`**
（唯一一份；轮换密码只改这里）。Terraform CD（`.github/workflows/terraform.yml`）把该路径
的每个 key 注入为 `TF_VAR_<key>`；`nexus_url`、`nexus_username` 在 `versions.tf` 有默认值。
本地运行时自行导出：

```text
TF_VAR_nexus_url=https://nexus.lab.ddupan.top
TF_VAR_nexus_username=admin
TF_VAR_nexus_password=<kv/infra/terraform/nexus 的 nexus_password>
```

`terraform/` 使用 `sonatype-nexus-community/sonatyperepo` 1.19.3（1.18 起有 OCI resource，
此前由已退役的 `reconcile-oci.sh` 调和；三个 OCI repository 以 `import` 块接管），当前声明：

- `ansible-galaxy-proxy` → `https://galaxy.ansible.com`，`ansible-public` group
- `go-proxy` → `https://proxy.golang.org`，`go-public` group
- `oci-proxy` → Docker Hub（认证拉取，见下）、`oci-proxy-ghcr` → ghcr.io、`oci-proxy-k8s` → registry.k8s.io，
  组成 `oci-public` group（按此顺序）；`oci-hosted`
- LDAP 连接 `ad`、`LdapRealm`、内部 CA 进 Nexus truststore、`platform-admins` → `nx-admin`

provider credential 不写入 HCL 或 tfvars。Nexus 已由 POC 转为正式使用；state 自 2026-10-04 起
位于 SeaweedFS S3 `tfstate/nexus/terraform.tfstate`（`backend.tf`），与其他 root 相同，使用
Bao `kv/k8s/seaweedfs-s3` 中受限的 `terraform` 身份，以 `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` 环境变量注入。离线验证命令：

```bash
terraform -chdir=apps/nexus/terraform init -backend=false
terraform -chdir=apps/nexus/terraform validate
```

### Docker Hub 认证

Docker Hub 对匿名拉取按出口 IP 限流，整个 lab 共用一个出口；被限流时 `oci-proxy` 对已缓存的
镜像也返回 404（2026-10-16 CI 因此失败）。所以 `oci-proxy` 以一个 Docker Hub 账号拉取：
`kv/infra/terraform/nexus` 的 `dockerhub_username` 与 `dockerhub_token`（Personal Access Token，
权限 **Public Repo Read-only**）。轮换只改这里，下一次 apply 生效。

### AD 登录

Nexus CE 没有 OIDC，管理员经 LDAPS（`dc1.ad.ddupan.top:636`，以内部 CA 校验主机名）用 AD
账号登录。只有 `platform-admins` 成员能登录（`user_ldap_filter`），该组经动态组映射为
`nx-admin`。绑定账号 `svc-nexus` 由 samba-ad 的 `samba_ad_service_accounts` 创建，密码由
play 生成、只存于 `kv/infra/nexus-ldap`（`username`/`password`），`tf.py` 把它交给
Terraform。play 整份覆盖写该路径，所以不能放进 `kv/infra/terraform/nexus`。本地管理员
`admin` 保留给 Terraform 并兼作 break-glass，realm 顺序上本地在前，DC 不可用时不影响它。

Terraform 同时把内置 `anonymous` 用户从默认的全仓库 `nx-anonymous` 角色收窄到
`ansible-public`、其返回制品 URL 使用的 `ansible-galaxy-proxy`、`go-public`，以及
`oci-public`/`oci-proxy` 的 `browse/read` 权限。`oci-hosted` 不向匿名用户开放。首次接管
已有实例时先执行
`terraform import sonatyperepo_user.anonymous anonymous,default`，再 apply；不要先启用默认的
全仓库匿名读取。

2026-09-20 的 POC 现场验收已确认：Flux 与 Pod Ready、PVC Bound、HTTPRoute 通过 HTTPS
返回 Nexus 状态 200，Samba DNS 已幂等收敛。全新客户端目录通过匿名入口下载
`community.general:11.2.0` 时冷缓存为 8.49 秒、热缓存为 1.89 秒，两次 tarball SHA-256
一致；`golang.org/x/text@v0.30.0` 为 2.92 秒与 1.51 秒。

## 客户端验收

先验证冷缓存，再原样重复命令验证热缓存；记录 Nexus 请求、上游流量和耗时，不只观察
命令成功。Ansible 配置的 URL 必须以 `/` 结尾：

```ini
[galaxy]
server_list = nexus

[galaxy_server.nexus]
url = https://nexus.lab.ddupan.top/repository/ansible-public/
```

```bash
ansible-galaxy collection install -r collections/requirements.yml \
  -p .ansible/collections
```

Go POC 使用：

```bash
GOPROXY=https://nexus.lab.ddupan.top/repository/go-public/ go mod download
```

私有 `git.ddupan.top/*` module 的 `GOPRIVATE`、凭据与是否允许 `direct` fallback 在实际
workflow 中单独决定；不要让私有 module path 意外发往公共 proxy。

OCI 使用 path-based routing：匿名公共拉取地址形如
`nexus.lab.ddupan.top/oci-public/library/alpine:3.22`，认证写入地址形如
`nexus.lab.ddupan.top/oci-hosted/<namespace>/<image>:<tag>`。2026-09-20 现场验收结果：

- `oci-public` 匿名代理拉取 Alpine 冷缓存 4.75 秒、热缓存 0.80 秒，digest 一致；
- `oci-hosted` 认证 push/pull 成功，匿名 pull 返回 401；
- amd64/arm64 OCI image index push 成功，两个平台 manifest 可见；
- Helm chart push/pull digest 与本地 tarball SHA-256 一致；
- Cosign 3.1.3 使用一次性密钥签名并验证成功，OCI 1.1 referrers API 返回一个
  `application/vnd.dev.sigstore.bundle.v0.3+json` artifact；
- BuildKit `registry` cache 以 `mode=max` 导出成功，销毁首个 builder 后由新 builder 导入，
  两个 `RUN` step 均明确命中 `CACHED`。

本机安装的测试客户端包括 `/usr/local/bin/cosign` 3.1.3；安装时核对官方 Linux amd64
binary SHA-256 `4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71`。
上述结果仍不代表备份恢复、外部 PostgreSQL 或正式 publisher service account 已完成；
这些项目通过前不得迁移或删除 zot。

## 数据与恢复

POC 的数据库、配置、blob、初始管理员状态都位于 `nexus-data` PVC。删除 Deployment
不会删除 PVC；删除 PVC 会永久删除整个 POC。当前没有独立备份，不能将它用于唯一副本的
正式制品。

恢复验证至少包括：停止写入、取得一致备份、在独立 PVC/实例恢复、登录、列出 repository、
拉取已缓存的 Ansible/Go 制品，并核对 OCI digest/referrers。正式化时再把数据库迁移至
外部 PostgreSQL，并分别定义数据库与 blob 的备份、恢复顺序和 RPO。

参考：

- [Nexus OCI repositories](https://help.sonatype.com/en/oci-repositories.html)
- [Nexus Ansible repositories](https://help.sonatype.com/en/ansible-repositories.html)
- [Nexus Go repositories](https://help.sonatype.com/en/go-repositories.html)
- [官方容器镜像](https://hub.docker.com/r/sonatype/nexus3)
