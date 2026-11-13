# SPIFFE/SPIRE workload identity

SPIRE 是 homelab 的机器与 workload identity 根。人类身份继续由 Samba AD 与
iam-login（sso.ddupan.top）提供；SPIRE 不替代人类 OIDC，也不承担目标服务的资源授权。

部署状态、workload 接入、JWT-SVID → OpenBao exchange、安全规则和故障恢复详见
[RUNBOOK.md](RUNBOOK.md)。本文只保留部署声明与关键恢复边界。

## 部署范围

Flux 安装 SPIFFE hardened charts：

- `spire-crds` `0.6.1`；
- 内部 fork 的 `spire` `0.30.2-ddupan.1`（SPIRE `1.15.3`），固定 Git tag
  `spire-0.30.2-ddupan.1`；
- SPIRE Server、Agent、Controller Manager、SPIFFE CSI Driver；
- OIDC Discovery Provider。

未启用 Tornjak、SPIRE Identity Exchange、SPIKE、federation、Delegated Identity
API 或 Broker API。Trust domain 是 `ddupan.top`，Kubernetes cluster name 是
`homelab`。

同一 Server 也接受 cluster name 为 `sandbox` 的 external PSAT attestation。SPIRE gRPC
只通过内网 `spire-server.lab.ddupan.top:8081` 暴露；external PSAT、external
controller-manager 与 bundle publisher 使用由 sandbox Ansible bootstrap 的独立、受限
kubeconfig。Sandbox 不运行第二套 Server 或 OIDC Provider。

集群外主机（当前只有 iam-login 构建 runner）以 `join_token` 证明，见
[external-agent/README.md](external-agent/README.md)。

OCI 实例使用自写插件 `oci_instance` 证明，插件仓库为
[panxiao81/spire-plugin-oci](https://github.com/panxiao81/spire-plugin-oci)，设计讨论见 #642。
- **证明方式**：agent 从 IMDS 取实例身份证书，server 用 `oci-instance-roots.pem` 验证证书链和
  `tenancy_allow_list`，再要求 agent 用 IMDS 私钥签名一次随机挑战。
- **Agent ID**：`spiffe://ddupan.top/spire/agent/oci_instance/<实例 OCID>`，叶证书轮换后不变，
  entry 可以直接以它为 parent。
- **Selector**：`oci_instance:{tenancy,compartment,instance,region}:<值>`。
- **升级插件**：同时修改 `values.yaml` 里的镜像 digest 和 `plugin_checksum`（取自 release 的
  `SHA256SUMS` 中 `server-linux-amd64` 那一行）。两者不一致时 spire-server 无法启动。
- **根证书轮换**：OCI 的接口带 `refreshIn`，说明会换根；当前根 2029-06-03 到期。轮换时用已认证的
  OCI 主体重新请求 `GET https://auth.ap-osaka-1.oraclecloud.com/v1/instancePrincipalRootCACertificates`，
  把返回的裸 base64 DER 包成 PEM，替换 `oci-instance-roots.pem` 后合并即可。目录挂载会跟随
  ConfigMap 更新，插件每次证明都会重新读取文件，不需要重启。

内部 fork 仅在上游 `spire-0.30.2` 基础上暴露
`use_pod_uid_for_agent_id`。现有 `sandbox` profile 保持 node UID 模式，供 DaemonSet
Agent 使用；独立的 `sandbox-kata` profile 复用同一 kubeconfig，但启用 Pod UID 模式，
供每个 Kata guest 内的临时 Agent 使用。不得把现有 `sandbox` profile 切换为 Pod UID，
否则会改变常驻 Agent 的 parent ID。

## PostgreSQL bootstrap

SPIRE registration datastore 使用 k3s 外的 pg-prod（Patroni），由 Ayatori 供应
（`clusters/ayatori-prod/spire-server.yaml`）：

```text
host:     pg-prod.lab.ddupan.top:5432（直连，verify-full）
database: spire
role:     spire
```

密码由 Ayatori 交付到 OpenBao，经 `database.yaml` 同步为 `spire-server/spire-server-pgprod`
的 `password` key（`spire-server.dataStore.sql.externalSecret`）。**不走 PgBouncer 连接池**：
SPIRE 的驱动是 lib/pq（jinzhu/gorm），其未命名语句跨两次 Sync，与 transaction 模式不兼容
（见 `infrastructure/shared-postgresql/README.md`「连接池」）。2026-10-13 自 k3s 内 CNPG 迁入。

**恢复顺序**：pg-prod 的服务器证书由 `renew-certificates.yml` 经 SPIRE→Bao 续签，而 SPIRE
Server 启动又需要 pg-prod。pg-prod 运行只用本地证书（60 天，剩 14 天续签），所以只有 SPIRE
连续停摆约 46 天才会互锁；届时以 Bao OIDC 人工登录续签 PG 证书即可解开。

PostgreSQL保存 registration state；SPIRE Server 的 disk KeyManager 仍使用一个
`1Gi`、`localpv-zfs-ceph` PVC 保存 trust-domain signing keys。数据库备份不能替代
该 PVC/密钥的备份。

## 身份签发策略

默认的全 Pod fallback `ClusterSPIFFEID` 已关闭。新增 workload 必须显式创建
`ClusterSPIFFEID`，并以 namespace、ServiceAccount、Pod label 等 selector 收窄。
不得仅因 Pod 能挂载 CSI socket 就给它签发身份。

## 宿主机本地开发身份

Kubernetes 节点 Agent 同时通过 hostPath 在宿主机发布 Workload API socket：

```text
/run/spire/agent-sockets/spire-agent.sock
```

Agent 已启用 Unix workload attestor，并为本机用户 `panxiao81`（UID `1000`）注册
`spiffe://ddupan.top/dev/panxiao81`。本地开发程序应设置：

```bash
export SPIFFE_ENDPOINT_SOCKET=unix:///run/spire/agent-sockets/spire-agent.sock
```

宿主机已安装与 Agent Pod 同版本的 `/usr/local/bin/spire-agent` 1.15.3，供本地进程从
Workload API 获取 JWT-SVID。二进制来自 SPIRE 官方 `linux-amd64-musl` release，安装时
核对 tarball SHA-256
`ca1a4d1155317bdd2afc7f36663828a10410c7c840e54725b90b4064b0a301c7`。升级 chart 时应
同步升级这个 CLI 并重新核对官方 checksum，不能长期混用版本。

该身份仅按 Unix UID 匹配，不是 SPIRE admin，也不会匹配 `sudo` 后以 root 运行的
进程。`ClusterStaticEntry.spec.parentID` 绑定当前 `laptop` Kubernetes node UID；若
节点被删除后重建，需从 `spire-server agent list` 取得新 Agent ID 并同步更新该字段。

下游授权仅绑定这个精确 SPIFFE ID：

- OpenBao `auth/jwt-spire/role/local-development` 接受 `aud=openbao`，签发 5 分钟
  token；允许读取和写入 KV v2 的 `kv/k8s/*` 与 `kv/infra/*` 子树、列出对应
  metadata、签发 `ai-agent` SSH
  短证书，以及查询、撤销自身 token；不允许删除/永久销毁 KV 数据或管理 auth；
- zot 接受 `aud=zot`，允许本机开发身份对所有 repository 执行
  `read/create/update/delete`；其他 SPIFFE 身份仍保持全仓库只读。

当前没有其他服务直接消费 SPIFFE 身份；Gitea runner 与 dynamic runner 是独立身份
使用方，NATS、SeaweedFS 等服务尚未通过 SPIFFE 做认证或授权。

JWT issuer：

```text
https://spire-oidc.ddupan.top
```

OIDC Discovery Provider 在 Pod 内部使用明文 HTTP。公网经 cloudflared 直达 Service，只放行
discovery 和 JWKS 两个路径；LAN 和 Pod 经 split-horizon 到 Envoy 的 `https-spire-oidc` listener。
旧名 `spire-oidc.lab.ddupan.top` 继续挂在 `https-lab` 上，Bao 和 iam-login 从那里取 JWKS。

接入 OpenBao 前必须从集群内和 LAN 分别验证 discovery document 的 `issuer` 与
上述 URL 完全一致。该 endpoint 只发布公开的 discovery metadata 和 JWKS，不能
要求登录（例如在前面加认证代理）。

## 首次部署与验证

合并后观察：

```bash
sudo k3s kubectl -n flux-system get kustomization spire
sudo k3s kubectl -n spire-mgmt get helmrelease
sudo k3s kubectl -n spire-server get pods,pvc
sudo k3s kubectl -n spire-system get daemonset,pods
```

必须先确认 `spire-crds` Ready，随后 `spire` Ready。SPIRE Server 应连接 PostgreSQL，
Agent 应通过 PSAT attestation 注册，CSI Driver 应在节点 Ready。

2026-09-14 已使用临时测试 Pod 与 `ClusterSPIFFEID` 完成
`aud=openbao` JWT-SVID → OpenBao 登录、token 自省和主动吊销的端到端验收；临时
Kubernetes 资源与 registration entries 已清理。

OpenBao 中对应的 Terraform 资源位于
`../../infrastructure/openbao/terraform/auth-spire.tf`。PoC role 只接受精确 subject
`spiffe://ddupan.top/ns/spire-poc/sa/spire-jwt-poc`，token 不包含 default policy，
且 `spire-poc` policy 不允许读取任何业务 secret。

## 恢复边界

- 恢复顺序：共享 PostgreSQL、SPIRE Server signing-key PVC、SPIRE Server、Agent；
- issuer URL 与 trust domain 初始化后不得随意修改；
- 丢失 signing keys 会使既有 SVID 和下游 JWKS 信任失效；
- PostgreSQL或 SPIRE 不可用时，不得用新的空数据库覆盖现有状态；
- 当前 Flux root 与本 Kustomization 均保持 `prune: false`，删除资源需单独审计。

## Issuer migration（`spire-oidc.lab` → `spire-oidc.ddupan.top`，2026-11，已完成）

外部验证方（Entra、Google、OCI）要从公网取 issuer，`spire-oidc.lab` 公网解析不到。校验 `iss` 的除下文三处外，
还有 Anthropic Console 里手工维护的 federation issuer。

1. **A** JWKS 加 `use:sig`；新名字在 LAN 可达（`https-spire-oidc` listener、证书、HTTPRoute、split-horizon）；
   Bao **临时清空 `bound_issuer`**。不改变线上 issuer。
2. **B** `jwtIssuer` 改新名，`additionalDomains` 改 lab 名；zot 与 iam-login 的 issuer 同步改；
   同时手工改 Anthropic Console 的 issuer。
3. **C** Bao `bound_issuer` 设为新名；清理仍写着 LAN-only 的注释。

JWT-SVID 的 TTL 是 1 小时，agent 缓存的旧 `iss` 令牌要到半衰期才换，所以 B 合并后要主动清缓存：

1. 确认 Flux 的 `spire` HelmRelease Ready，`curl https://spire-oidc.ddupan.top/.well-known/openid-configuration` 显示新 issuer。
2. `kubectl -n spire-system rollout restart ds/spire-agent`。
3. 在 Anthropic Console 把 issuer 改成新名，然后
   `kubectl -n ai-gateway create job --from=cronjob/anthropic-wif wif-manual` 确认能换到 token。
   现有 access token 还有最长 1 小时有效期，这一步要在它过期前做完。

Bao 的 `jwks_url` 和 iam-login 的 `jwk-set-uri` 继续用 lab 名，它们只取公钥，与 `iss` 无关。

## Issuer migration（`spire-oidc.ad` → `spire-oidc.lab`，2026-10）

JWT-SVID 只能带一个 `iss`，校验它的有三处：Bao `jwt-spire`（`bound_issuer`）、zot
（`bearer.oidc[].issuer`，且从 issuer URL 做 discovery，v2.1.21 无独立 discovery 地址）、
iam-login（`iam.clients.spiffe.issuer`，JWKS 地址单独配置）。按以下顺序切换：

1. **A1** discovery provider 以 `config.additionalDomains` 同时服务 lab 名，HTTPRoute 挂 `https-lab`。
2. **A2** Bao 改 `jwks_url`（lab）并**临时清空 `bound_issuer`**；iam-login `jwk-set-uri` 改 lab。
   CI 的 Terraform 自身经 jwt-spire 登录，Bao 必须在 SPIRE 切换前就接受新 issuer，否则修它的
   apply 登录不了。签名仍只认 SPIRE 的 JWKS，各 role 保留 `bound_audiences`。
3. **B** `jwtIssuer` 改 lab（`additionalDomains` 改为旧 ad 名）；zot 与 iam-login 的 issuer 改 lab。
   agent 缓存的旧 `iss` JWT-SVID 在几分钟内过期，期间 zot 推送与 iam-login 管理 API 会拒绝
   旧令牌（可接受的停机）；Bao 不受影响。
4. **C** Bao `bound_issuer` 设为 lab；移除 ad Host 与 HTTPRoute 旧名，退役 `spire-oidc.ad` 记录。
