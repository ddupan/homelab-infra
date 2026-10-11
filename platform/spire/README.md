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

内部 fork 仅在上游 `spire-0.30.2` 基础上暴露
`use_pod_uid_for_agent_id`。现有 `sandbox` profile 保持 node UID 模式，供 DaemonSet
Agent 使用；独立的 `sandbox-kata` profile 复用同一 kubeconfig，但启用 Pod UID 模式，
供每个 Kata guest 内的临时 Agent 使用。不得把现有 `sandbox` profile 切换为 Pod UID，
否则会改变常驻 Agent 的 parent ID。

## PostgreSQL bootstrap

SPIRE registration datastore 使用共享 CloudNativePG：

```text
host:     shared-postgresql-rw.shared-db.svc.cluster.local:5432
database: spire
role:     spire
```

数据库与 role 当前是手工创建的临时 bootstrap。密码只存在于
`spire-server/spire-postgresql` Secret 的 `password` key 中，不提交到 Git。
在 PostgreSQL tenant operator/DBaaS 接管前，不得删除该 Secret 或重置数据库
role 密码。

后续声明式管理必须保持这一 Secret 接口，或者在同一个变更中更新
`spire-server.dataStore.sql.externalSecret`，避免数据库凭据出现两个写入方。

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

稳定的 JWT issuer 预留为：

```text
https://spire-oidc.lab.ddupan.top
```

OIDC Discovery Provider 在 Pod 内部使用明文 HTTP，由 Envoy Gateway 的 `https-lab`
listener 使用 `*.lab.ddupan.top` wildcard certificate 终止 TLS。`HTTPRoute` 将
`spire-oidc.lab.ddupan.top` 转发到 ClusterIP Service，lab DNS 记录由 external-dns 发布。

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
