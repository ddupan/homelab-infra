# SeaweedFS (S3 storage)

**Purpose**
- Deploy SeaweedFS as the S3-compatible object store with the official Helm chart.
- Use chart-managed persistent storage and expose the admin UI through Tailscale.

**Files**
| File | Description |
| --- | --- |
| `values.yaml` | Helm values for the official SeaweedFS chart. |
| `helm.sh` | Installs or upgrades the SeaweedFS release. |

**Install**
1. 在 OpenBao `kv/k8s/seaweedfs-s3` 维护基础 S3 配置；zot 凭据单独以
   `kv/k8s/zot-s3` 为唯一来源。ESO 合成为 `seaweedfs-s3-config`，详见下文。
   不要把真实 AK/SK 放进 `values.yaml`。
2. Apply the manifests:
   ```bash
   bash ~/services/apps/seaweedfs/helm.sh
   ```

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
前缀。静态身份 `zot` 只有该 bucket 的 Read/Write/List/Tagging 权限，凭据唯一来源为
Bao `kv/k8s/zot-s3` 的 `access_key` / `secret_key`，同时供 zot consumer 和
SeaweedFS 服务端使用。

[ExternalSecret 模板](../../platform/external-secrets/externalsecrets.yaml) 保留
`kv/k8s/seaweedfs-s3` 的原有身份及其他配置，再追加 zot 身份与限定 bucket 的权限。
基础配置当前版本不保存 zot AK/SK；旧 KV 版本历史仍保留。新增其他身份时使用
KV compare-and-set 保留已有内容，不覆盖 Terraform 或其他应用的 AK/SK。
不要直接编辑生成的 Kubernetes Secret。该 ExternalSecret 已单独应用到集群，
目前仍未加入 ESO 的 Flux Kustomization，遵循该组件现有 ownership 边界。

运行版本 `4.22` 可在 Secret volume 更新后向 filer/内嵌 S3 的 `weed` 进程发送
SIGHUP，重新加载静态配置，无需重启共享 S3 服务。本次接入没有启用 SeaweedFS
OIDC/STS；SPIRE 认证发生在 zot 的客户端入口。
