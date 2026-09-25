# Hydra 与 OIDC Login/Consent PoC

本目录提供独立 Hydra 签发服务，以及一个薄的 **OIDC 上游适配器**。当前上游配置为
Authelia；适配器不连接 LDAP，也不管理用户目录。Samba AD、密码和 MFA 继续由现有
Authelia 链路负责。第一轮只接入人类和 Gitea，不实现 agent 动态授权。

```text
Gitea → Hydra → OIDC Login/Consent → Authelia → Samba AD
      ← OIDC ← 经验证的上游身份 ← OIDC callback
```

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
