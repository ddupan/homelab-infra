# zot OCI Registry

拉取用 `https://zot.lab.ddupan.top`（匿名），推送用 `https://zot-push.lab.ddupan.top`
（SPIRE 鉴权）；两个域名现在都指向同一个 `zot` 实例，匿名拉取见下文「匿名 pull token」。
`zot-reader` 已不挂路由，观察后删除。使用官方 Helm chart `0.1.124`，运行
zot `v2.1.21`，镜像固定到官方 linux/amd64 digest。

## 当前工作状态（2026-09-16 核验）

| 项目 | 状态 |
|---|---|
| 匿名拉取 | `zot.ad.ddupan.top` 已上线；空 `DOCKER_CONFIG` 的 crane pull 通过 |
| SPIRE 鉴权入口 | `zot-push.ad.ddupan.top` 已上线；真实 JWT-SVID 推送后可匿名拉取同一 digest |
| GitOps | 双入口配置已合并；Flux `zot` Kustomization 已应用 `d15733c`，状态 Ready |
| 运行与凭据同步 | `zot`、`zot-reader` HelmRelease 均 Ready，Pod 均 1/1；ESO SecretSynced |
| 临时配置清理 | 两个 HelmRelease 均无 `spec.values` 临时覆盖；暂停回写标记、测试身份和临时写权限已清理 |
| 接管复验 | 匿名拉取成功；推送入口无凭据返回 401，token realm 指向推送域名；接管未触发 Pod 重启 |

后续工作是给实际 CI 的 SPIFFE ID 配置具体仓库的 `create`/`update` 权限。
SPIRE 认证链路已经验证，但当前没有常驻 publisher 或删除授权；认证成功本身不代表
可以推送。S3 侧仍使用 Bao 管理的静态 AK/SK，尚未接入 SPIRE/STS。

## 存储与凭据

制品、manifest 和 OCI layout 保存在现有 SeaweedFS 的 `zot` bucket，前缀为
`registry/`，S3 endpoint 为 `https://s3.ad.ddupan.top`。**不创建 PVC**；chart 的
`/var/lib/registry` 是 `emptyDir`，仅用于运行时本地工作数据。

两个单副本实例共用同一 bucket 和前缀：`zot` 负责鉴权写入，`zot-reader` 负责匿名
读取。关闭跨仓库 dedupe，不额外部署 Redis/DynamoDB 缓存。只有写入实例启用 GC。
retention policy 只针对 `panxiao81/backstage`：仅保留 `latest`，历史 sha tag 与失去
tag 的 digest 在 24h 后回收（dev 镜像由 Flux 跟踪 `latest` 的 digest）。其余仓库由
`**` 兜底策略保留全部 tag，行为与未配置 retention 时一致；新增按仓库的清理规则时，
必须放在兜底策略之前，否则不会生效。增加副本、启用 dedupe 或搜索等
扩展前，需要重新检查共享元数据与缓存的持久化要求。

凭据链路：

```text
OpenBao kv/k8s/seaweedfs-s3
  → 原有 S3 身份及基础配置 ─┐
                         ├→ ESO 模板 → seaweedfs/seaweedfs-s3-config
OpenBao kv/k8s/zot-s3 ────┘                 → 完整 s3.config
  └→ ESO → zot/zot-s3 → zot 与 zot-reader 的 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

```

`kv/k8s/zot-s3` 是 zot AK/SK 的唯一维护来源。基础配置保留原有身份及其他字段，
不再保存 zot 凭据副本；[SeaweedFS ExternalSecret](../seaweedfs/s3-config-external-secret.yaml)
使用 ESO v2 模板追加 zot 身份。两个 Kubernetes Secret 都是自动生成的消费副本，
不手工编辑。Bao 的旧版本历史保留，回滚基础配置时模板也会替换其中的旧 zot 身份。

专用 S3 身份只有 `Read:zot`、`Write:zot`、`List:zot`、`Tagging:zot`、`WriteAcp:zot`（distribution 驱动每次写都带 `x-amz-acl: private`，SeaweedFS 4.52 起要求 WriteAcp），不能读取
Terraform 的 `tfstate` bucket。`kv/k8s/zot-s3` 的字段是 `access_key` 和
`secret_key`。AK/SK 不进入 Git、Helm values 或 CI；这里仍是静态 S3 凭据，尚未
接入 SPIRE/STS。

本次归一没有轮换密钥，生成的完整配置与归一前语义一致。当前模板只有一组 zot
凭据，尚未实现新旧密钥重叠轮换。后续轮换只修改 `kv/k8s/zot-s3`，但仍需协调
两个 ExternalSecret 同步：确认 SeaweedFS Secret volume 更新后向 filer 的
`weed` 进程发送 SIGHUP，再确认 zot Secret 更新并重启 `zot` 和 `zot-reader`（环境变量不会热更新）。
两端异步更新期间可能短暂认证失败；需要无中断轮换时先扩展模板支持新旧凭据重叠。

## SPIRE 认证和授权

| 参数 | 值 |
|---|---|
| issuer | `https://spire-oidc.ddupan.top` |
| JWT audience | `zot` |
| subject | `spiffe://ddupan.top/` 下的 workload SPIFFE ID |
| token endpoint | `https://zot-push.lab.ddupan.top/zot/auth/token` |
| 拉取入口 | 内网匿名读取所有仓库，不要求 SPIRE 身份 |
| 推送入口当前权限 | 受信身份可以读取所有仓库；没有常驻写入或删除授权 |

zot 通过已配置的 issuer discovery/JWKS 验证 JWT-SVID，再以 `sub` 作为授权身份。
不接受任意 issuer，不关闭 TLS/issuer 验证。新的 Kata CI 负责取得并更新自己的
JWT-SVID；确认其身份命名后，再添加针对具体 repository 的 `create`/`update`
授权，不能把整个 trust domain 都授予写权限。

zot `v2.1.21` 的 OIDC Bearer middleware 会在授权阶段之前拒绝无 token 请求。
因此使用两个官方 zot 实例与两个域名，避免修改上游镜像，也避免同域名下匿名
`/v2/` 返回 200 导致标准客户端跳过 token 交换的问题。

- `zot-reader` 叠加 `reader-values.yaml`，没有认证 middleware，只有
  `anonymousPolicy: [read]`。入口只转发 `/v2/` 的 GET/HEAD，并移除客户端遗留的
  Authorization/Cookie；直接访问 reader Service 也不能写入。
- `zot` 保留 SPIRE issuer/audience/subject 校验及仓库授权，`externalUrl`、
  Bearer realm、service 使用 `zot-push.lab.ddupan.top`；HTTPRoute 同时挂 ad 与 lab 两个名字。
- reader 关闭 GC，没有同步或扫描扩展；读取同一份 S3 制品，不复制 bucket，
  不新增 PVC 或 S3 密钥。镜像、安全上下文、资源和 Secret 引用由共用 values 继承。
- 两个配置的 `storageDriver` 必须保持一致；修改 S3 endpoint/bucket/prefix 时
  同时更新 `values.yaml` 与 `reader-values.yaml`。

推送客户端应登录 `zot-push.lab.ddupan.top`；拉取客户端无需登录。
已有 SPIRE 身份的进程可以通过 Workload API 获取 `aud=zot` 的 JWT-SVID，然后
通过 `docker login` 或 `crane auth login` 的 `--password-stdin` 交给 Registry。
用户名可以使用 `zot`，实际权限取自已验证 JWT 的身份。使用独立、权限为 `0700`
的临时 `DOCKER_CONFIG`，结束后删除；不要开启 shell tracing，不要打印 token，
不要把 token 放进命令参数。token 接口不会延长 SVID 有效期。

### Web UI 与 iam-login 登录

`https://zot.lab.ddupan.top/` 是 zot 自带 UI（`ui` + `search` 扩展），用 iam-login 登录
（`http.auth.openid`，客户端见 `apps/iam-login/terraform/clients.tf` 的 `zot`，凭据由
ExternalSecret `zot-sso` 渲染成 `credentialsFile`）。用户名取 `preferred_username`，组取
`groups`；`platform-admins` 组为 `adminPolicy`（可在 UI 删除），其他已登录用户按各仓库
`defaultPolicy` 只读。浏览器会话与 CLI 认证互不影响：bearer.oidc 与 openid 同时启用需要
v2.1.22（#4243）。会话密钥未固定，zot 重启后需要重新登录。search 的元数据库在 emptyDir，
启动时从 S3 重建。

### 匿名 pull token（单实例过渡中）

`zot` 实例同时服务匿名拉取与鉴权推送，`zot.lab`/`zot.ad` 的路由已从 `zot-reader` 移过来：

- 客户端无凭据时按 Bearer challenge 向 `/zot/auth/token` 要 token；zot 认不出凭据，
  经 `upstreamTokenEndpoint` 转发给集群内的 `oci-token-server`
  （[github.com/panxiao81/oci-token-server](https://github.com/panxiao81/oci-token-server)，
  `token-server.yaml`），拿回只含 `repository:<name>:pull` 的 Ed25519 签名 token，
  zot 用 `bearer.cert` 验证。JWT-SVID 仍由 zot 本地校验，不经过 token server。
- 签名密钥在 Bao `kv/k8s/zot-token-server`（`private_key` PKCS#8 PEM、`public_key`
  PKIX PEM），分别同步成 `zot-token-signing`（只给 token server）和
  `zot-token-verify`（只给 zot）。zot 只认一把公钥，轮换时写入新密钥对后同时重启
  `oci-token-server` 与 `zot`；token TTL 5 分钟，影响仅限正在进行的拉取。
- 转发走集群内明文 HTTP（`allowInsecureHttp`）。正常请求不带凭据；带了 zot 认不出的
  凭据（如输错的密码）也会原样转发，NetworkPolicy 只允许 `zot` 实例访问 token server。
- token server 镜像在 ghcr.io，不从 zot 拉取，避免启动时的循环依赖。

本机实测（zot v2.1.21）：docker、containerd、podman 匿名拉取成功，匿名推送 401，
JWT-SVID 推送不受影响。

同一仓库在两个入口使用相同路径和 tag/digest，例如 CI 推送到
`zot-push.lab.ddupan.top/team/image:tag`，部署时使用
`zot.lab.ddupan.top/team/image:tag`；无需在两个仓库间复制。

## 部署与网络

- 官方 chart 管理 Deployment、Service、ConfigMap 和 HTTPRoute。
- `persistence: false`，Service 为 ClusterIP，TLS 由已有 Envoy Gateway 的
  `https` listener 与内网通配符证书终止。
- 仅配置 Samba AD 内网 DNS；不创建公网 DNS 或 Cloudflare Tunnel route。
- NetworkPolicy 只允许现有 Envoy Gateway 数据面访问 zot 的 5000 端口。
- 拉取域名仅暴露 `/v2/` 的 GET/HEAD；推送域名暴露 `/v2/` 和
  `/zot/auth/token`，均不暴露内部健康检查或管理端点。
- namespace 使用 restricted PodSecurity，容器非 root、只读根文件系统。

`clusters/homelab/apps/zot.yaml` 已将 `zot` 和 `zot-reader` 一并纳入 Flux 管理。
两个 HelmRelease 通过共用 `zot-values` 继承基础配置，reader 再叠加
`zot-reader-values`。当前由 main 分支持续管理，不依赖本地覆盖或暂停回写。

后续若需临时验收，收尾时先确认 Git 管理的配置与目标运行配置一致，再移除
`spec.values` 临时覆盖及 `kustomize.toolkit.fluxcd.io/reconcile=disabled` 标记，
触发 zot Kustomization reconcile 并复验。临时测试身份和写权限不得留在持久配置中。

检查与渲染：

```bash
helm template zot --repo https://zotregistry.dev/helm-charts \
  --version 0.1.124 --namespace zot -f apps/zot/values.yaml --skip-tests
sudo k3s kubectl -n zot get helmrelease,pods,externalsecret,httproute
sudo k3s kubectl -n zot get pvc
```

上游 chart 的 Helm test Pod 不满足本 namespace 的 restricted 策略，也没有
SPIRE 凭据，因此不运行默认 `helm test`；使用下述真实身份验收。

## 验收与恢复

验收使用独立临时 Pod，通过 SPIFFE CSI socket 和真实 Workload API 取得 JWT-SVID，
没有修改现有 runner。仅在初始化 `verification/smoke:spire-s3` 测试镜像时临时
授予该测试身份针对该仓库的写权限；完成后必须撤回 HelmRelease override，并删除
临时 Pod、ServiceAccount 与 ClusterSPIFFEID。

验收项目：有效 SVID + crane pull、manifest digest 一致、错误 audience、错误
signature、过期 token、无凭据写入、跨仓库写入、只读身份写入和删除拒绝；另外检查
Pod 重建后镜像仍可拉取，以及 S3 身份不能访问 `tfstate`。

2026-09-14 已完成上述验收：HelmRelease Ready、HTTPRoute Accepted/ResolvedRefs，
DNS 第二次 Ansible check 为 `changed=0`；一分钟真实 JWT-SVID 到期后返回 401。
临时写权限已移除。测试镜像可供后续 CI 验证拉取：

```text
zot.ad.ddupan.top/verification/smoke:spire-s3
sha256:b8d3b977a1235022759470903dab4a46b7cf8107958624f1f76a323eabe37c5e
```

它是仅含验证文本的 OCI 测试镜像，没有可执行入口，不用于运行服务。

双域名验收还使用 `verification/anonymous-spire:smoke`：标准 crane 从
`zot-push.ad.ddupan.top` 登录、推送，再从 `zot.ad.ddupan.top` 使用空
`DOCKER_CONFIG` 拉取，两个入口的 digest 必须一致。验证匿名 blob HEAD、tags、
referrers，以及客户端保存旧凭据时的公共拉取。推送入口检查无凭据、错误签名、
错误 audience、过期 SVID、跨仓库写入和删除拒绝；公共入口拒绝所有写方法，
reader Service 直连也拒绝写入。测试完成后撤回临时单仓库写权限。

2026-09-16 上述双域名验收通过；SVID 过期后推送入口返回 401，匿名拉取不受
影响。临时写权限已撤销，两个 HelmRelease Ready；推送 DNS 第二次检查 changed=0。

匿名拉取示例：

```bash
crane pull zot.lab.ddupan.top/verification/anonymous-spire:smoke image.tar --format oci
```

鉴权推送示例（先通过 Workload API 将短期 JWT-SVID 保存到当前进程的 `ZOT_JWT`，
不要启用 shell tracing；示例中的仓库仍需提前给具体 SPIFFE ID 授权）：

```bash
export DOCKER_CONFIG="$(mktemp -d)"
printf '%s' "$ZOT_JWT" | crane auth login zot-push.lab.ddupan.top \
  --username zot --password-stdin
crane push image.tar zot-push.lab.ddupan.top/team/image:tag
rm -rf -- "$DOCKER_CONFIG"
unset DOCKER_CONFIG ZOT_JWT
```


Registry 恢复需要完整的 SeaweedFS bucket 数据、Bao 专用凭据和此目录配置。
zot 的临时目录不是制品备份。独立异机/离线备份尚未在本次部署中建立；不能把同一
SeaweedFS 内的数据副本当作独立灾备。重装 zot 不得删除 `zot` bucket。

参考：[官方 Kubernetes 安装](https://zotregistry.dev/v2.1.21/install-guides/install-guide-k8s/)、
[S3 存储](https://zotregistry.dev/v2.1.21/articles/storage/)、
[OIDC workload identity](https://github.com/project-zot/zot/blob/v2.1.21/examples/README-OIDC-WORKLOAD-IDENTITY.md)。

## 迁移到 `zot.lab` / `zot-push.lab`（随发版逐步进行）

两个 HTTPRoute 同时服务 ad 与 lab 名，镜像内容与 digest 不变，只是引用里的主机名不同。
各处在**自己的下一次发版**时改用 lab 名，不做集中切换：

| 位置 | 改什么 |
|---|---|
| ayatori `.gitea/workflows/release.yml` | `PUSH_REGISTRY` → `zot-push.lab…`，`PULL_REGISTRY` → `zot.lab…` |
| ayatori `deploy/ansible/roles/control_plane/defaults/main.yml` | `ayatori_image` |
| backstage `.gitea/workflows/ci.yml` | `PUSH_IMAGE`、`PULL_IMAGE`、`docker login` |
| 本仓库 `platform/flux-image-automation/backstage.yaml` | ImageRepository `image`；`apps/backstage/deployment.yaml` 由 image automation 随后改写 |
| gitea-dynamic-runner `.gitea/workflows/publish-images.yml`、`publish-runner-image.yml` | `PUSH_REGISTRY`、`PULL_REGISTRY` |
| 本仓库 `platform/{dynamic-runner,sandbox-dynamic-runner,sandbox-ci-runners}/` | runner 发版 PR 中的镜像引用 |
| iam-login `scripts/publish-image` | `repo=`、`docker login` |
| 本仓库 `apps/iam-login/deployment.yaml` | 发版 PR 中的镜像引用 |

`externalUrl` 与 bearer `realm`/`service` 已先切到 lab：客户端按 realm URL 取 token、原样回传
service，所以经 ad 名推送照样可用，而新改过来的发布方不再依赖 ad 名。全部改完后
（`git grep zot.ad.ddupan.top` 只剩历史文档）：探测与 catalog 跟随，再从 HTTPRoute 与 Samba
（`samba.retired`）移除 ad 名。
