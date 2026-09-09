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
1. Set real S3 access and secret keys in `values.yaml`.
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
- The chart-managed S3 secret uses the current AK/SK pair for the admin user.
