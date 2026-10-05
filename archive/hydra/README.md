> **已下线（2026-10-05）。** Gitea 已切换到 [iam-login](../../apps/iam-login/README.md)
> （`sso.ddupan.top`，登录源 ID 3 `sso`）。本目录只作历史记录，不再由 Flux 部署；Go 适配器的 CI
> 已删除。数据库、`kv/k8s/hydra` 与 Authelia 中的 `hydra-login` 客户端另行清理。

# Hydra 与独立 IAM 登录接入

本目录提供独立 Hydra 签发服务。当前分支将实验性 Hydra 登录入口接至 Spring `iam-login`
开发实例，由其执行 AD 密码、WebAuthn 和授权确认；不改变 issuer、Gitea 登录源或数据库。
旧 Go OIDC 适配器继续部署以便回退，Gitea 的直接 Authelia 登录源也保留。
该切换已于 2026-10-01 经 PR #168 合并并由 Flux 应用；下面原有 Go/Authelia 说明保留为回退路径资料。

```text
Gitea → Hydra → iam-login（Tailscale 开发实例）→ Samba AD + WebAuthn
```

## Spring 开发路径验收

源码版本：[iam-login 5f49a7c](https://git.ddupan.top/panxiao81/iam-login/commit/5f49a7c)。
开发 UI 是 `https://laptop.tail7e769.ts.net:18082`，已有 Passkey RP ID 保持不变。
Hydra 回调为 `/oauth2/start`、`/oauth2/consent`、`/oauth2/logout`；默认注销回到 `/signin`。
浏览器需要 Tailscale 连通性；开发服务暂由本地 JVM 容器运行，并非生产 Native 部署。

开发服务通过 `kubectl -n hydra port-forward --address 127.0.0.1 service/hydra-admin 18445:4445`
访问私有 Admin API。转发需在 Hydra 滚动更新后重连；验收运行器会循环重建该通道。
该通道与本地容器是临时验收依赖，必须保持运行；不修改 NetworkPolicy、
不新增 Admin HTTPRoute。临时运行配置与旧版回退备份仅保存在受限本地运行目录，不提交秘密。

验收前已只读核对目标 Gitea 账号的现有 Hydra 外部关联，并将旧 sub 显式绑定到 AD
稳定主体；不按邮箱重建关联、不修改 Gitea 账号或仓库权限。客户端管理仅允许有效 MFA 且
直接属于 AD Domain Admins 的用户；这是验收期明确指定的粗粒度管理组。

### 客户端管理 `/console`

iam-login 的客户端管理 API 是普通 resource server：只接受 Hydra 签发、`aud` 含 `iam-login`
且 `groups` 含管理组的 access token。`/console` 是调用该 API 的前端，在 Hydra 中登记为普通
**public** 客户端 `iam-admin-ui`；只有它被允许申请 audience `iam-login`（Hydra 按客户端登记的
audience 白名单执行），所以其他应用拿到的管理员 token 不能调用该 API。

浏览器直接向 Hydra 换取 token，因此 `hydra.yaml` 为 public 端口开启 CORS，只允许开发实例
origin；不放行 cookie 凭据。Gitea 等服务端客户端不受影响。

`iam-admin-ui` 无 secret，与 `gitea` 一样经 Admin 带外登记（它是 public 客户端，iam-login API
看不到也删不掉它，恢复同样走此通道）：

```sh
curl -fsS -X POST http://127.0.0.1:18445/admin/clients -H 'Content-Type: application/json' -d '{
  "client_id": "iam-admin-ui", "client_name": "IAM 管理",
  "redirect_uris": ["https://laptop.tail7e769.ts.net:18082/console/callback"],
  "grant_types": ["authorization_code"], "response_types": ["code"],
  "scope": "openid groups", "audience": ["iam-login"], "token_endpoint_auth_method": "none",
  "subject_type": "public", "metadata": {"iam_login_enabled": true}}'
```

开发实例另需 `iam.clients.admin-ui-client-id=iam-admin-ui` 与 `iam.clients.admin-groups`（组名）；未配置时 `/console` 不提供，API
无法获得可用 token（fail closed）。

从 Gitea `/user/oauth2/hydra` 发起，应进入新密码/Passkey 页，确认授权后返回原账号，核对
仓库权限。当前 Gitea client 未登记 front/back-channel 或 post-logout 回调，不能声称 Gitea 会话会
随 IAM 注销。应用的注销协议兼容性需单独验收。旧 `authelia` 登录源始终保留。

开发配置关闭 Boot 默认 LDAP health indicator：它未配置目录连接，不对应同用户 bind 的
AD 仓储。总健康检查仍验证数据库，真实 AD 认证由本次人类登录验收，不将 readiness 当作
AD 凭据有效性的证明。

Hydra 的 login/consent URL 是全局配置，本次影响全部经 Hydra 的登录请求（当前接入 Gitea），
不影响直接走 Authelia 的应用。不要在无法访问 Tailscale 开发实例时合并此切换。
验收失败时 revert 本次回调变更，恢复旧 Go 的 `/login`、`/consent`；不删除客户端、签名密钥、
数据库、用户关联或 Passkey。最终 `auth.ddupan.top` 同源部署另开 PR，不在此次切换范围内。

## 原 Go/Authelia 路径与回退资料

目标入口：

- `https://hydra.ad.ddupan.top`：Hydra 公共 OAuth2/OIDC endpoint。
- `https://hydra-login.ad.ddupan.top`：上游 OIDC 登录及 consent 适配器。
- `hydra-admin.hydra.svc.cluster.local:4445`：仅集群内管理接口，无 HTTPRoute。

均为 LAN/Tailscale 入口，复用 Envoy `eg/https` wildcard TLS。没有增加公网 tunnel。
部署及实际验收状态以 wiki 和对应 PR 为准，文件存在不表示登录已验收。

## 首次使用与边界

在 Gitea 登录页选择 `hydra`，跳转到 Authelia 完成现有人类认证，再返回原有 Gitea
账号。旧 `authelia` 登录源保留。Gitea 的账号关联和资源权限仍由 Gitea 维护。

适配器要求验证上游 issuer、audience、签名、过期时间和 nonce，使用 PKCE S256，
并把单次 state 绑定到 Secure/HttpOnly/SameSite=Lax cookie。短期登录事务只存内存，
最多 1024 个、10 分钟过期；单副本重启后正在登录的用户需重试，不存人类密码或 token。

Hydra subject 为上游 `(issuer, sub)` 的 SHA-256 加 `human:` 前缀，与可变邮箱/用户名
分离。第一轮要求上游返回经过验证的 email 及 preferred_username；这些 claims 必须
明确配置进 ID token。更换 issuer 会改变本 PoC 的 subject，正式迁移前需要身份绑定设计。

仅为显式 `ALLOWED_CLIENTS=gitea` 自动 consent，scope 限于 openid/profile/email/groups；
拒绝额外 access-token audience，不发 refresh token。只按实际请求 scope 释放 claims。
这不是通用的无人确认授权服务。组当前透传，沿用 Gitea 的 gitea-admins 映射；统一组
模型和 agent 认证均在后续阶段。不存在对 Authelia 专有协议的调用。

NetworkPolicy 限制公共端口只接收 Envoy 流量，Hydra admin 只允许适配器访问。
Hydra 使用正式模式，TLS 由 Envoy 终止；不使用 `--dev`。管理操作使用受控
`kubectl port-forward`，不要将 admin 接口暴露到 Gateway。

## 依赖、秘密与初始化

依赖共享 CloudNativePG、OpenBao/ESO、Authelia OIDC、Envoy、Samba DNS、zot 镜像仓库。
Hydra 使用独立 `hydra` database/role，不与其他应用共享数据库角色。

`kv/k8s/hydra` 保存 dsn、system_secret、upstream_client_secret、upstream_client_digest、
gitea_client_secret；通过 ExternalSecret 投射，值不写入 Git。Bootstrap 创建角色及数据库
后才启动 Hydra migration。system_secret 必须持久保存，不得在重启时随机重建。

Authelia 中新增 confidential client `hydra-login`：

- redirect URI：`https://hydra-login.ad.ddupan.top/callback`；
- authorization policy：two_factor；grant：authorization_code；PKCE：S256；
- token endpoint auth：client_secret_basic；scope：openid/profile/email/groups；
- claims policy：把 preferred_username、name、email、email_verified、groups 放入 ID token；
- client secret 的 PBKDF2 digest 存入 Authelia，原值仅供适配器使用。

Authelia 尚非 Flux 管理。修改 Helm values 时保留所有已有 clients 与 secret 引用，
通过 `--reuse-values` 和最小 overlay 增加客户端，不能以本目录配置覆盖其完整 values。

Hydra 中注册 confidential client `gitea`，redirect URI 为
`https://git.ddupan.top/user/oauth2/hydra/callback`，grant/response 为 authorization_code/code，
scope 为 openid/profile/email/groups，token endpoint auth 为 client_secret_basic。
Gitea 启动时读取 OIDC discovery，所以应先确认 Hydra 健康和 discovery 可达，再接入 Gitea。

## 构建与检查

```bash
cd apps/hydra/login-consent
go test -race ./...
go vet ./...
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o login-consent .
docker build -t hydra-login-consent:VERSION .
```

Go module 独立，依赖由 go.sum 锁定；Dockerfile 固定基础镜像 digest。
使用已授权的短期 SPIFFE zot 凭据发布镜像，部署使用匿名拉取入口与不可变 digest。
不把 registry 凭据写入源码或 build args。

```bash
kubectl kustomize apps/hydra
sudo k3s kubectl -n hydra get deployment,pod,externalsecret,httproute
sudo k3s kubectl -n hydra logs deployment/hydra -c migrate
sudo k3s kubectl -n hydra logs deployment/hydra-login
```

日志不输出上游 token、授权 code、challenge 或秘密。登录失败先查两端 Pod 状态、
DNS/discovery 连通性、client redirect URI 和 scope，再由用户重新发起登录。
不要在故障排查中关闭签名验证、MFA 或 state/nonce 校验。

## 恢复与回退

保留共享 PostgreSQL 中 Hydra 数据及 OpenBao 秘密；数据库持有 clients、会话及签名密钥，
单独重建 Deployment 不能替代恢复数据库。先恢复依赖，再启动 Hydra 和适配器。
当前恢复仍依赖 homelab 共享基础设施，不能声称已完成独立灾备。

第一轮不切换 Authelia 的主入口。撤回 Gitea 的新增 Hydra 登录源即可回到旧入口；
先撤消费者，再考虑停用 Hydra。不要删除旧 Authelia 登录源、用户或数据库作为回退手段。

跨服务设计见 [独立 IAM 草案](https://git.ddupan.top/panxiao81/homelab-wiki/src/branch/main/architecture/independent-iam-draft.md)。
