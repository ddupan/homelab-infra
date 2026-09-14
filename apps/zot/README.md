# zot OCI Registry

内网入口为 `https://zot.ad.ddupan.top`。使用官方 Helm chart `0.1.124`，运行
zot `v2.1.21`，镜像固定到官方 linux/amd64 digest。

## 存储与凭据

制品、manifest 和 OCI layout 保存在现有 SeaweedFS 的 `zot` bucket，前缀为
`registry/`，S3 endpoint 为 `https://s3.ad.ddupan.top`。**不创建 PVC**；chart 的
`/var/lib/registry` 是 `emptyDir`，仅用于运行时本地工作数据。

首期单副本，关闭跨仓库 dedupe，不额外部署 Redis/DynamoDB 缓存。保留 zot GC，
暂不配置自动删除已发布版本的 retention policy。增加副本、启用 dedupe 或搜索等
扩展前，需要重新检查共享元数据与缓存的持久化要求。

凭据链路：

```text
OpenBao kv/k8s/seaweedfs-s3
  → 原有 S3 身份及基础配置 ─┐
                         ├→ ESO 模板 → seaweedfs/seaweedfs-s3-config
OpenBao kv/k8s/zot-s3 ────┘                 → 完整 s3.config
  └→ ESO → zot/zot-s3 → zot 的 AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY

```

`kv/k8s/zot-s3` 是 zot AK/SK 的唯一维护来源。基础配置保留原有身份及其他字段，
不再保存 zot 凭据副本；[SeaweedFS ExternalSecret](../../platform/external-secrets/externalsecrets.yaml)
使用 ESO v2 模板追加 zot 身份。两个 Kubernetes Secret 都是自动生成的消费副本，
不手工编辑。Bao 的旧版本历史保留，回滚基础配置时模板也会替换其中的旧 zot 身份。

专用 S3 身份只有 `Read:zot`、`Write:zot`、`List:zot`、`Tagging:zot`，不能读取
Terraform 的 `tfstate` bucket。`kv/k8s/zot-s3` 的字段是 `access_key` 和
`secret_key`。AK/SK 不进入 Git、Helm values 或 CI；这里仍是静态 S3 凭据，尚未
接入 SPIRE/STS。

本次归一没有轮换密钥，生成的完整配置与归一前语义一致。当前模板只有一组 zot
凭据，尚未实现新旧密钥重叠轮换。后续轮换只修改 `kv/k8s/zot-s3`，但仍需协调
两个 ExternalSecret 同步：确认 SeaweedFS Secret volume 更新后向 filer 的
`weed` 进程发送 SIGHUP，再确认 zot Secret 更新并重启 zot（环境变量不会热更新）。
两端异步更新期间可能短暂认证失败；需要无中断轮换时先扩展模板支持新旧凭据重叠。

## SPIRE 认证和授权

| 参数 | 值 |
|---|---|
| issuer | `https://spire-oidc.ad.ddupan.top` |
| JWT audience | `zot` |
| subject | `spiffe://ddupan.top/` 下的 workload SPIFFE ID |
| token endpoint | `https://zot.ad.ddupan.top/zot/auth/token` |
| 当前权限 | 受信身份可以读取所有仓库；没有常驻写入或删除授权 |

zot 通过已配置的 issuer discovery/JWKS 验证 JWT-SVID，再以 `sub` 作为授权身份。
不接受任意 issuer，不关闭 TLS/issuer 验证。新的 Kata CI 负责取得并更新自己的
JWT-SVID；确认其身份命名后，再添加针对具体 repository 的 `create`/`update`
授权，不能把整个 trust domain 都授予写权限。

现阶段拉取也需要 JWT-SVID。原定内网匿名拉取尚未启用：zot `v2.1.21` 的
OIDC Bearer middleware 会在授权阶段之前拒绝无 token 请求，单独增加
`anonymousPolicy` 无法解决。匿名读取与 SPIRE 写入共存需后续单独验证方案。

已有 SPIRE 身份的进程可以通过 Workload API 获取 `aud=zot` 的 JWT-SVID，然后
通过 `docker login` 或 `crane auth login` 的 `--password-stdin` 交给 Registry。
用户名可以使用 `zot`，实际权限取自已验证 JWT 的身份。使用独立、权限为 `0700`
的临时 `DOCKER_CONFIG`，结束后删除；不要开启 shell tracing，不要打印 token，
不要把 token 放进命令参数。token 接口不会延长 SVID 有效期。

## 部署与网络

- 官方 chart 管理 Deployment、Service、ConfigMap 和 HTTPRoute。
- `persistence: false`，Service 为 ClusterIP，TLS 由已有 Envoy Gateway 的
  `https` listener 与内网通配符证书终止。
- 仅配置 Samba AD 内网 DNS；不创建公网 DNS 或 Cloudflare Tunnel route。
- NetworkPolicy 只允许现有 Envoy Gateway 数据面访问 zot 的 5000 端口。
- HTTPRoute 只暴露 `/v2/` 和 `/zot/auth/token`，不暴露内部健康检查或管理端点。
- namespace 使用 restricted PodSecurity，容器非 root、只读根文件系统。

首次已按用户授权从本地执行 `kubectl apply -k apps/zot`，由集群 Helm controller
安装。`clusters/homelab/apps/zot.yaml` 是 GitOps composition；对应文件合并进入
Flux 跟踪分支后，才由根 Kustomization 持续管理，不能把未提交的本地部署写成
已完成 Git 接管。

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

Registry 恢复需要完整的 SeaweedFS bucket 数据、Bao 专用凭据和此目录配置。
zot 的临时目录不是制品备份。独立异机/离线备份尚未在本次部署中建立；不能把同一
SeaweedFS 内的数据副本当作独立灾备。重装 zot 不得删除 `zot` bucket。

参考：[官方 Kubernetes 安装](https://zotregistry.dev/v2.1.21/install-guides/install-guide-k8s/)、
[S3 存储](https://zotregistry.dev/v2.1.21/articles/storage/)、
[OIDC workload identity](https://github.com/project-zot/zot/blob/v2.1.21/examples/README-OIDC-WORKLOAD-IDENTITY.md)。
