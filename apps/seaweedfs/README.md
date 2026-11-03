# SeaweedFS (S3 storage)

**Purpose**
- Deploy SeaweedFS as the S3-compatible object store with the official Helm chart.
- Use chart-managed persistent storage and expose the admin UI through Tailscale.

**Files**
| File | Description |
| --- | --- |
| `values.yaml` | Helm values for the official SeaweedFS chart（经 ConfigMap `seaweedfs-values` 注入 HelmRelease）。 |
| `helmrelease.yaml` / `helmrepository.yaml` | Flux HelmRelease，固定 chart 版本；chart 版本同时决定镜像版本。 |
| `httproute-s3.yaml` | `s3.ad.ddupan.top` 入口。 |
| `terraform/` | bucket 与 IAM（用户 / access key / policy）经 AWS provider 直连 SeaweedFS。 |
| `helm.sh` | 仅 break-glass：Flux 不可用时手工 upgrade，版本须与 HelmRelease 一致。 |

**Install**
1. 在 OpenBao `kv/k8s/seaweedfs-s3` 维护基础 S3 配置；zot 凭据单独以
   `kv/k8s/zot-s3` 为唯一来源。ESO 合成为 `seaweedfs-s3-config`，详见下文。
   不要把真实 AK/SK 放进 `values.yaml`。
2. 由 Flux（`clusters/homelab/apps/seaweedfs.yaml`）部署；改 `values.yaml` 或 chart
   版本后合并到 `main` 即可。

**Flux 接管与 4.48 升级**
- 2026-10-04 接管原 release（chart `4.22.0`，revision 4），同时升级到 chart `4.48.0`。`prune: false`。
- 4.48 的两处 breaking：volume `idx` 不再允许 emptyDir（改为与 `.dat` 同一 PVC）；
  `weed admin` >= 4.46 无认证拒绝非回环监听，暂用 `allowInsecureBind` 维持原状。
- 回滚点：`data/ceph/<pvc>@pre-4.48` ZFS 快照（三个 PVC 同一原子快照）。

**Access**
- Inside the cluster, the S3 endpoint is `http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333`.
- The filer UI is available at `http://seaweedfs-filer.seaweedfs.svc.cluster.local:8888`.
- Public access is routed through Cloudflare Tunnel at `https://obj.ddupan.top`.
- The admin UI is exposed through Tailscale on the `seaweedfs-admin` Ingress.
- For local testing, use port-forward:
  ```bash
  kubectl -n seaweedfs port-forward svc/seaweedfs-s3 8333:8333 \
    svc/seaweedfs-filer 8888:8888 \
    svc/seaweedfs-admin 23646:23646
  ```

**Notes**
- The chart manages master, volume, filer, S3, and admin components.
- The filer uses the ESO-managed `seaweedfs-s3-config` Secret for static S3 identities.

## zot 制品存储

`zot` bucket 专用于 [zot Registry](../zot/README.md)，OCI 数据位于 `registry/`
前缀。静态身份 `zot` 只有该 bucket 的 Read/Write/List/Tagging/WriteAcp 权限（WriteAcp：zot 写入时带 `x-amz-acl: private`，4.52 起需要它），凭据唯一来源为
Bao `kv/k8s/zot-s3` 的 `access_key` / `secret_key`，同时供 zot consumer 和
SeaweedFS 服务端使用。

[ExternalSecret 模板](s3-config-external-secret.yaml) 保留
`kv/k8s/seaweedfs-s3` 的原有身份及其他配置，再追加 zot 身份与限定 bucket 的权限。
基础配置当前版本不保存 zot AK/SK；旧 KV 版本历史仍保留。新增其他身份时使用
KV compare-and-set 保留已有内容，不覆盖 Terraform 或其他应用的 AK/SK。
不要直接编辑生成的 Kubernetes Secret。该 ExternalSecret 随本目录的 Flux Kustomization
部署（2026-11-03 起；此前为手工 apply）。

运行版本 `4.22` 可在 Secret volume 更新后向 filer/内嵌 S3 的 `weed` 进程发送
SIGHUP，重新加载静态配置，无需重启共享 S3 服务。本次接入没有启用 SeaweedFS
OIDC/STS；SPIRE 认证发生在 zot 的客户端入口。

## TechDocs 文档存储

`techdocs` bucket 存放各仓库发布的 Backstage TechDocs 静态站点，由
`terraform/techdocs.tf` 管理：IAM 用户 `techdocs-publisher`（Get/Put/DeleteObject/List，供 CI
经 OpenBao role `ci-techdocs-publisher` 取用）与 `techdocs-reader`（Get/List，供
Backstage），access key 由 Terraform 生成并写入 `kv/k8s/techdocs-s3-publisher`、
`kv/k8s/techdocs-s3-reader`（字段 `access_key` / `secret_key`）。不要手工改这两条 KV，
下次 apply 会覆盖；轮换凭据用 `terraform apply -replace` 对应的 access key。

## Terraform provider registry

`terraform-registry` bucket 以静态文件实现 Terraform provider registry 协议，入口
`https://terraform.lab.ddupan.top`（`httproute-terraform-registry.yaml`：只放行 GET，路径固定在
`/terraform-registry/` 之下，其他 bucket 不可经此名访问）。bucket policy 只允许匿名 `GetObject`
（无列举、无写入），因此**只能放公开发布物**。

- 内容：`.well-known/terraform.json`（`providers.v1`）、`v1/providers/<ns>/<type>/versions`、
  `v1/providers/<ns>/<type>/<version>/download/<os>/<arch>`，以及 zip、`SHA256SUMS` 与其 GPG 签名。
- 写入分两半：provider 仓库的 release job（SPIFFE `ci/panxiao81/terraform-provider-*/release`）经 OpenBao role
  `ci-terraform-registry-publisher` 读取 `kv/k8s/terraform-registry-s3-publisher`（IAM 用户
  `terraform-registry-publisher`，Terraform 生成），只上传 zip 与 `SHA256SUMS`；维护者本机 `scripts/publish`
  校验后以 YubiKey 签名子钥（`8A887573EFE9762D`）签名，写 download 文档与 versions 索引。CI 不持有签名密钥。
- 消费：`source = "terraform.lab.ddupan.top/ddupan/homelab"`，无需 `.terraformrc`。

## Terraform（bucket / IAM）

S3 管理不进 Ayatori，由 `terraform/` 经 AWS provider 直接调用 SeaweedFS 的 S3 与内嵌
IAM API（同一端点 `https://s3.ad.ddupan.top`）。已接入 CI（`TF_ROOTS`），合并即 apply。

- provider 身份是静态 `s3-admin`（Admin），只存在 `kv/k8s/seaweedfs-s3`，TF 用 vault
  provider 读取；backend 仍用 `terraform` 受限身份。本地运行：
  `python3 .gitea/scripts/tf.py run apps/seaweedfs/terraform plan`（需 `BAO_TOKEN`）。
- filer 开启 `-s3.iam.readOnly=false`。动态身份存于 filer `/etc/iam/identities/` 与
  `/etc/iam/policies.json`，与静态文件合并生效；备份依赖 filer 元数据。
- **TF 管理的用户名不得与静态身份重名**：对静态身份的 IAM 写操作静默成功但不生效。
- `aws_iam_user` 需要 SeaweedFS >= 4.48（更早版本 GetUser 不返回 Arn）。
- 内联 policy 的 action 通配：4.48 接受 `s3:Get*`/`s3:Put*`/`s3:List*`，拒绝 `s3:Delete*`
  （MalformedPolicyDocument），删除权限写 `s3:DeleteObject`。
- 现有 bucket 以 `import` 纳管并 `prevent_destroy`。新 bucket 加到 `local.buckets`。
