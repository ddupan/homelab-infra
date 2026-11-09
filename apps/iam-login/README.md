# iam-login（sso.ddupan.top）

[iam-login](https://git.ddupan.top/panxiao81/iam-login) 的 Native 部署：AD 密码 + Passkey 登录，
进程内 OAuth2/OIDC 授权服务器。issuer 为 `https://sso.ddupan.top`，作为长期 issuer，不是开发域名；
`auth.ddupan.top`（Authelia）已于 2026-10-11 退役，全部 RP 已迁到这里；Hydra 已下线（`archive/hydra`）。

```text
浏览器 ─ Cloudflare ─ tunnel ─┐
                              ├─→ Service iam-login:8080 ─→ Samba AD（LDAPS，同用户 bind）
集群内 RP（Gitea）─ Envoy ────┘                          └─→ pg-prod（iam_login，Ayatori 供应）
```

- 公网：Cloudflare tunnel 直达 Service（`infrastructure/cloudflared/terraform/main.tf`），
  CNAME 与 tunnel 路由同在该文件。
- LAN 与 Pod：split horizon 解析到 Envoy `https-sso` listener，证书
  `platform/cert-manager/certificate-sso-ddupan.yaml`。Gitea 换 token 与启动时取 discovery 都不经 WAN。
- TLS 在 Envoy 或 Cloudflare 终止，应用信任两者的 `X-Forwarded-Proto`；NetworkPolicy 只放行这两个 namespace。
- 会话存数据库（Spring Session JDBC，表由应用 Flyway 创建），重启不登出；WebAuthn challenge 存 `webauthn_challenge` 表。

## 配置分层

`application.yaml`（ConfigMap）只放环境值。功能开关（`iam.*.enabled`）在 Native 构建时固定于 iam-login 的
`application-prod.yaml`，Deployment 以 `SPRING_PROFILES_ACTIVE=prod` 激活；在 ConfigMap 里写开关会被忽略，
与构建不一致时 iam-login 拒绝启动。AD 连接使用 Boot 标准键 `spring.ldap.*`，整体 `/actuator/health` 含 LDAPS 连接检查。

## 秘密：`kv/k8s/iam-login`

| 属性 | 内容 | 生成 |
|---|---|---|
| `signing_key` | PKCS#8 PEM RSA 签名私钥 | `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048` |
| `truststore` | base64 PKCS#12：JDK 标准 cacerts **加**内部 `ddupan.top Internal CA`（JVM 全局生效，只放内部 CA 会让 Let's Encrypt 站点如 spire-oidc 握手失败） | `keytool -importkeystore` 自 cacerts，再 `-importcert` 内部 CA，口令 `changeit` |
| `totp_key` | base64 32 字节随机数，加密数据库里的验证器 App 密钥（`IAM_TOTP_KEY`）。**更换或丢失会让所有已设置的验证器 App 失效**，用户需改用 Passkey 或由管理员重置 | `openssl rand -base64 32`（2026-10-14 写入） |

## 秘密：`kv/k8s/iam-login-ldap`

AD 只读服务账号 `svc-iam-login`（`username` 为 UPN，`password`），由 samba-ad 的 play 建账号时生成并写入，
不要手工改（见 `infrastructure/samba-ad`）。渲染为 `SPRING_LDAP_USERNAME/PASSWORD`，用于 Boot 的 LDAP 连接：
健康检查，以及用户不在场时读目录（refresh 时确认账号仍存在且未禁用）。用户登录仍以用户自己的凭据 bind。

签名密钥丢失会使已签发 token 失效，所有 RP 需重新登录，但不影响账号关联；不要随部署重新生成。
轮换：新密钥放在 `signing-keys` 首位并保留旧密钥，旧 token 全部过期后再移除（见 iam-login
`docs/authorization-server.md`）。

## 数据库

经 Ayatori 自助申请（`clusters/ayatori-prod/iam-login.yaml`）：pg-prod 上的 `iam_login` 库与同名
登录角色，表由应用 Flyway 迁移创建。凭据只交付到 OpenBao，本 namespace 以自己的 SA
`iam-login-database` 登录 bao（role/policy 在 `infrastructure/openbao/terraform`，只能读这一份凭据），
`database.yaml` 渲染为 `SPRING_DATASOURCE_*`，经连接池 6432（pgjdbc 与 transaction 模式兼容，已压测）。ExternalSecret 固定 Tenant status 中的
`credentialVersion`，凭据重发时需显式更新。连接 `sslmode=verify-full`，服务端证书由内部 CA 签发，
CA 公钥证书来自 trust-manager 分发的 ConfigMap `internal-ca`（`platform/trust-manager`）。库中保存 passkey、客户端与授权记录，恢复以
数据库为准。

## 镜像

iam-login main 的 CI 在 Native 浏览器测试通过后，用其 `Dockerfile` 打包同一个二进制，以 executor
Pod 的 SPIFFE 身份推到 `zot-push.lab.ddupan.top/iam/iam-login:<commit>`（`publish` job，见 `platform/dynamic-runner/`）。
部署从 `zot.lab.ddupan.top` 匿名拉取，按 commit tag 固定版本；升级由 PR 把 `deployment.yaml` 的 tag 改成新的 commit。

## Passkey 与管理

- RP ID 是 `sso.ddupan.top`，开发实例（`laptop.tail7e769.ts.net`）上的 passkey 不能沿用，首次登录重新注册。
- 首次注册只要求近期 AD 密码（见 iam-login `docs/webauthn.md`）。入口在公网，**上线后应尽快为
  每个账号完成注册**，未注册的账号在此期间只受 AD 密码保护。
- 客户端管理：`https://sso.ddupan.top/console`，要求直接属于 `Domain Admins`。
- 机器调用方（Terraform，`terraform-provider-homelab`）以 JWT-SVID（aud `iam-login`）调用管理 API，
  只放行 `application.yaml` 中 `iam.clients.spiffe.admin-ids` 精确列出的 SPIFFE ID（Terraform CD 的 plan/apply job）。
  验签时 Pod 访问 `https://spire-oidc.lab.ddupan.top/keys`。

## OIDC 客户端（Terraform）

客户端在 `terraform/clients.tf` 声明，由 Terraform CD（`TF_ROOTS`）经自研 provider
`terraform.lab.ddupan.top/ddupan/homelab` 管理。provider 不持有凭据：调用方的 JWT-SVID（audience
`iam-login`）须在 `iam.clients.spiffe.admin-ids` 中（CD 的 plan/apply job 与笔记本开发身份）。`/console`
只用于查看与应急，在那里的改动会表现为 drift。

- 新增客户端：在 `clients.tf` 加资源，合并后 apply；secret 只在创建与轮换时可得，写入 OpenBao 供应用读取。
- `gitea` 以 import 纳管（2026-10-05），secret 不可读回、state 中为 null，`kv/k8s/gitea-sso` 仍是人工写入的值；
  轮换（设置 `secret_rotation`）会让旧 secret 立即失效，需同时写入 kv 并重启 Gitea。

## 检查

```bash
kubectl kustomize apps/iam-login
sudo k3s kubectl -n iam-login get deploy,pod,externalsecret,httproute
curl -fsS https://sso.ddupan.top/.well-known/openid-configuration
```
