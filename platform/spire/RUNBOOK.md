# SPIRE 与 OpenBao workload identity runbook

本文记录 homelab 中 workload 如何取得 SPIFFE 身份、如何把 JWT-SVID 交换成
OpenBao 短期 token，以及相关的部署、接入、验证和恢复操作。这里的命令默认在
`laptop` 上执行。

## 1. 当前架构

```text
Kubernetes Pod
  │  Pod ServiceAccount + Pod UID
  ▼
SPIRE Agent（每节点 DaemonSet，k8s workload attestor）
  │  Unix socket: /spiffe-workload-api/spire-agent.sock
  │  Agent 自身通过 k8s_psat 向 Server 证明节点身份
  ▼
SPIRE Server（trust domain: ddupan.top）
  ├─ registration state → shared PostgreSQL
  ├─ signing keys       → localpv-zfs-ceph PVC
  └─ JWT public keys    → OIDC Discovery Provider
                            │
                            ▼
                 https://spire-oidc.lab.ddupan.top
                            │ discovery + JWKS
                            ▼
                 OpenBao auth/jwt-spire/login
                            │ exact sub + aud + role
                            ▼
                    短期、最小权限 Bao token
```

各层职责必须保持分离：

- Kubernetes ServiceAccount 是 Pod 的初始身份证明，不是跨平台 IAM token；
- SPIRE 负责 workload 身份、证明和 SVID 签发，不保存业务 secret；
- OpenBao 验证 JWT-SVID，并把身份映射为本地 policy；
- 目标服务最终仍负责自己的资源授权，SPIFFE ID 本身不等于权限；
- 人类身份继续使用 Samba AD + Authelia OIDC，不经过 `jwt-spire`。

## 2. 线上对象与稳定标识

| 项目 | 当前值 |
|---|---|
| SPIRE chart | `0.30.2-ddupan.1`（内部 fork，基于 `0.30.2`） |
| SPIRE | `1.15.3` |
| SPIRE CRDs chart | `0.6.1` |
| trust domain | `ddupan.top` |
| Kubernetes cluster name | `homelab` |
| Controller Manager class | `spire-mgmt-spire` |
| JWT issuer | `https://spire-oidc.lab.ddupan.top` |
| OpenBao auth mount | `jwt-spire` |
| OpenBao login endpoint | `auth/jwt-spire/login` |
| SPIRE Server namespace | `spire-server` |
| Agent/CSI namespace | `spire-system` |
| Helm management namespace | `spire-mgmt` |

`trustDomain`、`clusterName`、issuer URL 与 Controller Manager class 都进入身份或
下游信任配置。修改它们不是普通 rename，必须按 trust-domain migration 处理。

## 3. 身份与授权模型

Kubernetes workload 的默认 SPIFFE ID 约定为：

```text
spiffe://ddupan.top/ns/<namespace>/sa/<service-account>
```

身份必须同时在两侧声明：

1. SPIRE `ClusterSPIFFEID` 决定哪些 Pod 可以取得该身份；
2. OpenBao JWT role 决定该 `sub`、`aud` 能换取哪些 policy。

这两个声明是有意的双重门：只有 SPIRE entry 而没有 Bao role 时，workload 能取得
SVID，但不能登录 Bao；只有 Bao role 而没有 SPIRE entry 时，没有 workload 能铸造
满足条件的 JWT。

禁止使用以下宽泛规则：

- 给所有 Pod 启用 fallback `ClusterSPIFFEID`；
- OpenBao role 接受整个 `spiffe://ddupan.top/*`；
- 仅按 namespace 匹配高权限身份，却不限制 ServiceAccount 和 Pod labels；
- 多个安全边界不同的 workload 共用同一个 ServiceAccount；
- 给 workload token 附带 `default` 或 `admin` policy。

## 4. 新 workload 接入流程

以下示例为 namespace `example` 中的 ServiceAccount `example-worker`。

### 4.1 创建专用 ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: example-worker
  namespace: example
```

不要使用 namespace 的 `default` ServiceAccount。

### 4.2 声明 ClusterSPIFFEID

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: example-worker
  labels:
    spire.spiffe.io/class-name: spire-mgmt-spire
spec:
  className: spire-mgmt-spire
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: example
  podSelector:
    matchLabels:
      app.kubernetes.io/name: example-worker
  spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
```

Controller Manager 最终会为具体 Pod UID 创建 registration entry。检查状态：

```bash
sudo k3s kubectl get clusterspiffeid example-worker -o yaml
sudo k3s kubectl -n spire-server exec statefulset/spire-server -c spire-server -- \
  /opt/spire/bin/spire-server entry show \
  -spiffeID spiffe://ddupan.top/ns/example/sa/example-worker
```

`status.stats.entryFailures` 必须是 `0`。Pod 重建后 UID 会变化，短暂看到旧 entry
属于正常收敛过程。

### 4.3 挂载 Workload API

```yaml
spec:
  serviceAccountName: example-worker
  containers:
    - name: worker
      volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      env:
        - name: SPIFFE_ENDPOINT_SOCKET
          value: unix:///spiffe-workload-api/spire-agent.sock
  volumes:
    - name: spiffe-workload-api
      csi:
        driver: csi.spiffe.io
        readOnly: true
```

挂载 socket 不会自动获得身份。Agent 会对调用进程执行 workload attestation，只有
selector 命中 registration entry 才签发 SVID。

应用应优先使用 SPIFFE SDK，通过 Workload API 按需取得并自动轮换 SVID。不要把
JWT-SVID 写入 Kubernetes Secret、镜像、持久卷、CI artifact 或日志。

### 4.4 声明 OpenBao policy

在 `infrastructure/openbao/terraform/policies/` 中为 workload 建独立 policy。例如：

```hcl
path "kv/data/apps/example/*" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
```

不要直接复用 `admin`。动态数据库凭据、SSH 签名和 KV 应分别授权到精确 path。

### 4.5 声明 OpenBao JWT role

在 `infrastructure/openbao/terraform/auth-spire.tf` 增加 role：

```hcl
resource "vault_jwt_auth_backend_role" "example_worker" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "example-worker"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/ns/example/sa/example-worker"
  }

  token_policies          = [vault_policy.example_worker.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}
```

同一个 JWT 可以请求多个 audience，但 Bao role 只接受 `openbao`。未来接入其他服务时
应给对应服务使用独立 audience，不能把 `openbao` 当作通用 audience。

Terraform apply 必须遵循 `infrastructure/openbao/README.md` 的 remote-state 和认证
流程。任何包含 destroy/replace 的 plan 都应停止审查；JWT role/policy 的正常新增应为
纯 `add`。

## 5. JWT-SVID 交换流程

逻辑请求如下：

```http
POST /v1/auth/jwt-spire/login
Content-Type: application/json

{
  "role": "example-worker",
  "jwt": "<aud=openbao 的 JWT-SVID>"
}
```

成功响应中的 `auth.client_token` 是短期 Bao token。它只应存在于进程内存或
job-scoped `tmpfs`；通常无需主动续期，过期前重新用 Workload API 获取 JWT-SVID 并
登录即可。

如果使用 SPIRE CLI 调试，`1.15.3` 的 JSON 输出顶层是数组，JWT 位于：

```text
.[0].svids[0].svid
```

调试脚本必须把 JSON 捕获到变量中，禁止直接输出：

```bash
set -euo pipefail

JWT_RESPONSE="$(spire-agent api fetch jwt \
  -audience openbao \
  -socketPath /spiffe-workload-api/spire-agent.sock \
  -output json)"
JWT_SVID="$(printf '%s' "$JWT_RESPONSE" | jq -er '.[0].svids[0].svid')"

LOGIN_PAYLOAD="$(jq -nc \
  --arg role example-worker \
  --arg jwt "$JWT_SVID" \
  '{role:$role,jwt:$jwt}')"
LOGIN_RESPONSE="$(curl --fail-with-body --silent --show-error \
  -H 'Content-Type: application/json' \
  --data "$LOGIN_PAYLOAD" \
  https://bao.lab.ddupan.top:8200/v1/auth/jwt-spire/login)"

export BAO_ADDR=https://bao.lab.ddupan.top:8200
export BAO_TOKEN="$(printf '%s' "$LOGIN_RESPONSE" | jq -er '.auth.client_token')"
```

不要在 shell 中启用 `set -x`，不要 `echo "$JWT_SVID"` 或输出完整 login response。
cleanup 阶段可以尽力主动吊销；短 TTL 仍是主要安全边界：

```bash
bao token revoke -self
unset BAO_TOKEN JWT_SVID JWT_RESPONSE LOGIN_RESPONSE LOGIN_PAYLOAD
```

## 6. CI 与 AI Agent 使用方式

CI job/Agent 不应接收长期 `BAO_TOKEN`。标准启动顺序是：

1. 调度到带 SPIRE Agent 与 CSI Driver 的节点；
2. 以专用 ServiceAccount 启动，挂载 Workload API socket；
3. 获取目标 audience 的 JWT-SVID；
4. 用对应 Bao role 换取短期 token；
5. 在同一进程树中以环境变量调用 `tofu`、Ansible 或其他工具；
6. cleanup 尝试 `revoke-self`，随后销毁 job/VM/容器。

Gitea Actions 可使用
[`panxiao81/ci-actions/spiffe-openbao-login@v1`](https://git.ddupan.top/panxiao81/ci-actions/src/tag/v1/spiffe-openbao-login)
完成步骤 3、4 和 cleanup 时的 `revoke-self`。runner 只负责提供 Node.js 20、
`spire-agent` 与 Workload API socket；role、audience 及是否登录由 workflow 明确声明，
目标侧 Bao policy 仍负责最终授权。该 Action 必须满足：

- 不把 JWT-SVID 或 Bao token 写到 stdout/stderr；
- 不把凭据传入命令行参数，避免出现在进程列表；
- job 结束后销毁 runner 及其 Actions 临时文件；
- 不尝试把短期 token 上传到 Actions Secret 或 artifact；
- role、audience 和目标命令由受审查的 pipeline 配置决定。

Action 会按 GitHub Actions 协议把短期 token 写入 `GITHUB_ENV` 和 `GITHUB_STATE`，因此
只允许用于一次性 Pod/VM runner，不能用于共享或持久 runner。只读取 Nexus public
repository 时不需要 Bao 登录，可直接使用
[`panxiao81/ci-actions/setup-nexus@v1`](https://git.ddupan.top/panxiao81/ci-actions/src/tag/v1/setup-nexus)
配置 Ansible Galaxy、Go module proxy 与 OCI endpoint。

Kubernetes 以外的执行环境不能伪造 ServiceAccount。未来应分别使用 host SPIRE
Agent、TPM/DevID、cloud instance identity、GitHub OIDC 等初始证明接入同一信任模型。

## 7. 日常检查

### Flux 与 Helm

```bash
sudo k3s kubectl -n flux-system get kustomization spire
sudo k3s kubectl -n spire-mgmt get helmrepository,helmrelease
```

### Server、Agent 与 CSI

```bash
sudo k3s kubectl -n spire-server get pods,pvc
sudo k3s kubectl -n spire-system get daemonset,pods
sudo k3s kubectl -n spire-server exec statefulset/spire-server -c spire-server -- \
  /opt/spire/bin/spire-server agent list
```

Agent 应显示 `Attestation type: k8s_psat` 与 `Can re-attest: true`。

### OIDC discovery 与 JWKS

```bash
dig @192.168.10.5 spire-oidc.lab.ddupan.top A +short
dig @192.168.10.127 spire-oidc.lab.ddupan.top A +short
curl --fail --silent \
  https://spire-oidc.lab.ddupan.top/.well-known/openid-configuration | jq
curl --fail --silent https://spire-oidc.lab.ddupan.top/keys | jq '.keys | length'
```

discovery 的 `issuer` 必须严格等于
`https://spire-oidc.lab.ddupan.top`。路径、scheme、hostname 或尾部 `/` 的差异都会
导致 JWT 验证失败。JWKS 是公开验证材料，不是 secret。

### OpenBao

管理员只检查非敏感配置：

```bash
export BAO_ADDR=https://bao.lab.ddupan.top:8200
bao auth list
bao read auth/jwt-spire/role/<role-name>
bao policy read <policy-name>
```

## 8. 故障排查

### `no identity issued`

依次检查：

```bash
sudo k3s kubectl get clusterspiffeid <name> -o yaml
sudo k3s kubectl -n <namespace> get pod <pod> \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,SA:.spec.serviceAccountName,LABELS:.metadata.labels
sudo k3s kubectl -n spire-server exec statefulset/spire-server -c spire-server -- \
  /opt/spire/bin/spire-server entry show -spiffeID <expected-spiffe-id>
```

确认 namespace、ServiceAccount、Pod labels 与 entry 中的 `k8s:pod-uid`。刚启动的
一次性 Job 可能在 Controller Manager 建 entry 前请求身份并失败；生产客户端应重试
Workload API，而不是假设 Pod 一启动身份就已可用。

### `auth/jwt-spire/login` 返回 400

常见原因：

- JWT audience 不是 role 的 `bound_audiences`；
- JWT `sub` 与 role 的 `bound_claims.sub` 不完全一致；
- issuer 与 `bound_issuer` 不一致；
- Bao 无法解析或验证 `spire-oidc.lab.ddupan.top`；
- issuer/JWKS route 被 Authelia forward-auth 拦截；
- SVID 已过期，或者节点与 Bao 时钟偏差过大；
- 脚本错误解析 CLI JSON，向 Bao 发送了空 JWT。

排查时只解码 JWT header/claims，禁止记录原始 token。公开 endpoint 可单独验证：

```bash
curl --fail https://spire-oidc.lab.ddupan.top/.well-known/openid-configuration
curl --fail https://spire-oidc.lab.ddupan.top/keys
```

### CSI mount 失败

如果事件包含 `driver name csi.spiffe.io not found`：

```bash
sudo k3s kubectl get csidriver csi.spiffe.io
sudo k3s kubectl -n spire-system get daemonset spire-spiffe-csi-driver
sudo k3s kubectl -n spire-system logs daemonset/spire-spiffe-csi-driver \
  -c spiffe-csi-driver --tail=100
```

首次安装时 OIDC Provider/业务 Pod 可能早于 CSI registration，短暂 mount retry 正常；
持续失败才需要处理。

### Server 无法连接 PostgreSQL

```bash
sudo k3s kubectl -n shared-db get cluster shared-postgresql
sudo k3s kubectl -n spire-server get secret spire-postgresql \
  -o go-template='{{range $k, $_ := .data}}{{$k}}{{"\n"}}{{end}}'
sudo k3s kubectl -n spire-server logs statefulset/spire-server \
  -c spire-server --tail=100
```

Secret 必须有 `password` key。禁止为排障直接输出或提交其值。

## 9. 轮换、备份与恢复

SPIRE 会自动轮换 X.509 CA 与 JWT signing key；OIDC Provider 从 Workload API 获取
当前 JWKS，下游按 `kid` 验证。正常轮换不应要求更新 Bao role。

必须备份两类不同状态：

- PostgreSQL：registration entries、agent state 和 SPIRE metadata；
- `spire-data-spire-server-0` PVC：disk KeyManager 的 trust-domain signing keys。

仅恢复 PostgreSQL 而丢失 PVC，不等于恢复 SPIRE。签名密钥丢失会使既有 SVID/JWKS
信任链失效。恢复顺序：

1. 恢复共享 PostgreSQL；
2. 恢复 signing-key PVC；
3. 启动 SPIRE Server；
4. 确认 bundle/JWKS 后启动或恢复 Agent；
5. 最后恢复依赖 SPIRE 登录 Bao 的 workload。

不要以空数据库或空 PVC“修复”启动失败。若确实需要重建 trust domain，应把它作为
全体下游重新建立信任的灾难恢复事件处理。

## 10. 当前 PoC 结论与后续工作

2026-09-14 已完成并清理一次临时 PoC：

- workload 取得 `aud=openbao` JWT-SVID；
- 精确 subject 成功登录 `jwt-spire/spire-poc`；
- 返回 token 仅含 `spire-poc` policy，TTL 为 300 秒，无 default policy；
- `lookup-self` 成功，随后 `revoke-self` 并验证 token 已失效；
- 临时 Namespace、Pod/Job、ServiceAccount、`ClusterSPIFFEID` 与 registration entries
  均已删除；
- Terraform 完整 plan 最终为 `No changes`。

下一步不是重复 PoC，而是为真实 CI/AI Agent 定义：

- 独立 ServiceAccount 和稳定 SPIFFE ID；
- 按能力拆分的 OpenBao policy（例如 SSH CA、S3 state、数据库动态凭据）；
- 通用 credential-exec 包装器；
- token 获取失败、过期与 cleanup 的客户端重试语义；
- Kubernetes 外 host/VM/microVM 的 SPIRE Agent attestation 方案。
