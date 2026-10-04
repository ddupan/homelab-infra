# iam-login（sso.ddupan.top）

[iam-login](https://git.ddupan.top/panxiao81/iam-login) 的 Native 部署：AD 密码 + Passkey 登录，
进程内 OAuth2/OIDC 授权服务器。issuer 为 `https://sso.ddupan.top`，作为长期 issuer，不是开发域名；
`auth.ddupan.top`（Authelia）与 Hydra 在各 RP 迁走前继续运行。

```text
浏览器 ─ Cloudflare ─ tunnel ─┐
                              ├─→ Service iam-login:8080 ─→ Samba AD（LDAPS，同用户 bind）
集群内 RP（Gitea）─ Envoy ────┘                          └─→ shared-postgresql（iam_login）
```

- 公网：Cloudflare tunnel 直达 Service（`infrastructure/cloudflared/terraform/main.tf`），
  DNS 由 `infrastructure/dns/records.yml` 生成。
- LAN 与 Pod：split horizon 解析到 Envoy `https-sso` listener，证书
  `platform/cert-manager/certificate-sso-ddupan.yaml`。Gitea 换 token 与启动时取 discovery 都不经 WAN。
- TLS 在 Envoy 或 Cloudflare 终止，应用信任两者的 `X-Forwarded-Proto`；NetworkPolicy 只放行这两个 namespace。
- 单副本：登录进度与 MFA 因素保存在内存 session，重启后正在登录的人需重试。

## 秘密：`kv/k8s/iam-login`

| 属性 | 内容 | 生成 |
|---|---|---|
| `db_password` | `iam_login` 角色密码 | 随机生成，同时设置到 PostgreSQL |
| `signing_key` | PKCS#8 PEM RSA 签名私钥 | `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` |
| `truststore` | base64 PKCS#12，只含公开的 `ddupan.top Internal CA` | `keytool -importcert`，口令 `changeit`（只含公钥证书，口令无保护意义） |

签名密钥丢失会使已签发 token 失效，所有 RP 需重新登录，但不影响账号关联；不要随部署重新生成。
轮换：新密钥放在 `signing-keys` 首位并保留旧密钥，旧 token 全部过期后再移除（见 iam-login
`docs/authorization-server.md`）。

数据库 `iam_login`（owner `iam_login`）在共享 CloudNativePG 中带外创建，与 Hydra 相同；表由应用的
Flyway 迁移创建。数据库保存 passkey、客户端与授权记录，恢复以数据库为准。

## 镜像

由 iam-login 仓库的 `Dockerfile` 打包 Native 二进制（构建方法见其注释），推送到
`zot-push.ad.ddupan.top/iam/iam-login`，部署使用 `zot.ad.ddupan.top` 匿名拉取与不可变 digest。
首次发布由开发身份 `spiffe://ddupan.top/dev/panxiao81` 手动推送；CI 自动发布待构建 runner
获得 SPIFFE 身份后再做。

## Passkey 与管理

- RP ID 是 `sso.ddupan.top`，开发实例（`laptop.tail7e769.ts.net`）上的 passkey 不能沿用，首次登录重新注册。
- 首次注册只要求近期 AD 密码（见 iam-login `docs/webauthn.md`）。入口在公网，**上线后应尽快为
  每个账号完成注册**，未注册的账号在此期间只受 AD 密码保护。
- 客户端管理：`https://sso.ddupan.top/console`，要求直接属于 `Domain Admins`。

## 检查

```bash
kubectl kustomize apps/iam-login
sudo k3s kubectl -n iam-login get deploy,pod,externalsecret,httproute
curl -fsS https://sso.ddupan.top/.well-known/openid-configuration
```
