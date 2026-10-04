# iam-login（sso.ddupan.top）

[iam-login](https://git.ddupan.top/panxiao81/iam-login) 的 Native 部署：AD 密码 + Passkey 登录，
进程内 OAuth2/OIDC 授权服务器。issuer 为 `https://sso.ddupan.top`，作为长期 issuer，不是开发域名；
`auth.ddupan.top`（Authelia）与 Hydra 在各 RP 迁走前继续运行。

```text
浏览器 ─ Cloudflare ─ tunnel ─┐
                              ├─→ Service iam-login:8080 ─→ Samba AD（LDAPS，同用户 bind）
集群内 RP（Gitea）─ Envoy ────┘                          └─→ pg-prod（iam_login，Ayatori 供应）
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
| `signing_key` | PKCS#8 PEM RSA 签名私钥 | `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` |
| `truststore` | base64 PKCS#12，只含公开的 `ddupan.top Internal CA` | `keytool -importcert`，口令 `changeit`（只含公钥证书，口令无保护意义） |

签名密钥丢失会使已签发 token 失效，所有 RP 需重新登录，但不影响账号关联；不要随部署重新生成。
轮换：新密钥放在 `signing-keys` 首位并保留旧密钥，旧 token 全部过期后再移除（见 iam-login
`docs/authorization-server.md`）。

## 数据库

经 Ayatori 自助申请（`clusters/ayatori-prod/iam-login.yaml`）：pg-prod 上的 `iam_login` 库与同名
登录角色，表由应用 Flyway 迁移创建。凭据只交付到 OpenBao，本 namespace 以自己的 SA
`iam-login-database` 登录 bao（role/policy 在 `infrastructure/openbao/terraform`，只能读这一份凭据），
`database.yaml` 渲染为 `SPRING_DATASOURCE_*`。ExternalSecret 固定 Tenant status 中的
`credentialVersion`，凭据重发时需显式更新。连接 `sslmode=verify-full`，服务端证书由内部 CA 签发，
CA 公钥证书 `internal-ca.pem` 随 ConfigMap 提供。库中保存 passkey、客户端与授权记录，恢复以
数据库为准。

## 镜像

iam-login main 的 CI 在 Native 浏览器测试通过后，用其 `Dockerfile` 打包同一个二进制，以 runner 的
SPIFFE 身份推到 `zot-push.ad.ddupan.top/iam/iam-login:<commit>`（见 `platform/spire/external-agent/`）。
部署使用 `zot.ad.ddupan.top` 匿名拉取与不可变 digest，更新由 PR 修改 `deployment.yaml`。

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
