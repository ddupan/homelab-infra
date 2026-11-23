# spire-identity-exchange（GitHub Actions job → SPIFFE 身份）

GitHub 上的 job 跑在 homelab 的 ARC runner（`platform/sandbox-arc`）上，但 homelab 的服务（Bao、zot）
只认 SPIFFE 身份。本目录部署 SPIFFE 官方的 [spire-identity-exchange](https://github.com/spiffe/spire-identity-exchange)
（v0.6.0，上游标注实验性；CI 不是核心负载，接受这个风险）：job 交两个 token，换一个 JWT-SVID。

```
runner Pod ── PSAT(aud=spire-identity-exchange) + GitHub OIDC(aud=spire-identity-exchange) ──▶ exchange
exchange ── 校验两者、防重放、生成 selectors ──▶ 本节点 SPIRE Agent（Delegated Identity API）
Agent ── 匹配 platform/spire/github-ci.yaml 的 entry ──▶ JWT-SVID(aud=zot|openbao)
```

- 只有组合 stack `arc`：PSAT 证明请求来自 sandbox 的 ARC runner Pod（TokenReview），GitHub token
  证明是哪个仓库、workflow、ref、event。只有 GitHub token（例如 GitHub 托管 runner）或只有 PSAT 都换不到。
- SPIFFE ID 只由 SPIRE entry 决定（`ci/github/<owner>/<repo>/<workflow>`），exchange 配置里没有。
- 可签发的 audience 只有 `zot`、`openbao`（`mintAudiences`）。

## 为什么不用 spire chart 自带的 exchange 子 chart

它在 exchange Pod 里带一个以 x509pop（spiffe 模式）向 server 证明的 agent sidecar。中央 SPIRE server
的 x509pop 已用于 Cinc 节点（externalPKI 模式），同类插件只能配一个，所以改为由 sandbox 节点 agent
提供 Delegated Identity API：admin socket 挂到节点（`sockets.admin.mountOnHost`），`authorized_delegates`
只列本 exchange 的 SVID（`platform/sandbox-spire/agents/values.yaml`）。entry 挂在覆盖两个 sandbox
agent 的 node alias `spiffe://ddupan.top/node/sandbox-agents` 下，exchange 落在哪个节点都能签。

## 客户端

exchange 用自己的 X509-SVID 提供 HTTPS（`https://spire-identity-exchange.spire-identity-exchange.svc`，
端口 443），证书只有 URI SAN。客户端从 WebPKI 的 `https://spire-bundle.lab.ddupan.top` 取 SPIFFE
trust bundle 作 CA，按 SPIFFE ID `spiffe://ddupan.top/sandbox/spire-identity-exchange` 校验对端，
不按 DNS 名。请求：

```
POST /api/v1/svid/arc/jwt?format=token
Authorization: Bearer k8s=<PSAT>:github-actions=<GitHub OIDC token>
{"audiences": ["zot"]}
```

## 加一个身份

在 `platform/spire/github-ci.yaml` 加 entry：`repository_id`/`repository_owner_id`（数字 ID，改名不变）、
`job_workflow_ref:path`、写入类绑定 `ref:refs/heads/main` + `event_name:push`，并在目标服务给这个
SPIFFE ID 授权。token 里没有 job 名：需要单独身份的 job 拆成单独的 workflow 文件。
