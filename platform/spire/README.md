# SPIFFE/SPIRE workload identity

SPIRE 是 homelab 的机器与 workload identity 根。人类身份继续由 Samba AD 与
Authelia 提供；SPIRE 不替代人类 OIDC，也不承担目标服务的资源授权。

## 部署范围

Flux 安装 SPIFFE hardened charts：

- `spire-crds` `0.6.1`；
- `spire` `0.30.2`（SPIRE `1.15.3`）；
- SPIRE Server、Agent、Controller Manager、SPIFFE CSI Driver；
- OIDC Discovery Provider。

未启用 Tornjak、SPIRE Identity Exchange、SPIKE、federation、Delegated Identity
API 或 Broker API。Trust domain 是 `ddupan.top`，Kubernetes cluster name 是
`homelab`。

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

稳定的 JWT issuer 预留为：

```text
https://spire-oidc.ad.ddupan.top
```

OIDC Discovery Provider 在 Pod 内部使用明文 HTTP，由现有 Envoy Gateway 的
`https` listener 使用 `*.ad.ddupan.top` wildcard certificate 终止 TLS。对应的
`HTTPRoute` 将 `spire-oidc.ad.ddupan.top` 转发到 ClusterIP Service；AD DNS 记录
声明在 `../../infrastructure/dns/records.yml`，由 Samba DNS Ansible 流程应用。

接入 OpenBao 前必须从集群内和 LAN 分别验证 discovery document 的 `issuer` 与
上述 URL 完全一致。该 endpoint 只发布公开的 discovery metadata 和 JWKS，不能
在其 HTTPRoute 上添加 Authelia forward-auth。

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

首个业务验收另行增加一个专用测试 Pod 与 `ClusterSPIFFEID`，验证取得
`aud=openbao` 的 JWT-SVID 后登录 OpenBao。PoC 完成前不修改生产认证方式。

## 恢复边界

- 恢复顺序：共享 PostgreSQL、SPIRE Server signing-key PVC、SPIRE Server、Agent；
- issuer URL 与 trust domain 初始化后不得随意修改；
- 丢失 signing keys 会使既有 SVID 和下游 JWKS 信任失效；
- PostgreSQL或 SPIRE 不可用时，不得用新的空数据库覆盖现有状态；
- 当前 Flux root 与本 Kustomization 均保持 `prune: false`，删除资源需单独审计。
