# HTTP Echo (Gateway API workload)

**Purpose**
- Preserve a tiny HTTP echo `Deployment + Service` as a future GitOps canary.
- The current `HTTPRoute` still references the retired `contour-gateway`; do not
  apply this folder until it is migrated and reviewed against Envoy Gateway.

**Resources**
| File | Description |
| --- | --- |
| `deployment.yaml` | Two replicas of `hashicorp/http-echo` returning `hello from contour gateway`. |
| `service.yaml` | ClusterIP service on port 80 targeted by the route. |
| `httproute.yaml` | Gateway API `HTTPRoute` that targets `contour-gateway` and the `http-echo` service. |

**How to verify**

Migration and verification are intentionally deferred. Update `parentRefs` to the
reviewed Envoy Gateway and choose a hostname covered by its listener before apply.

**Notes**
- This README records the old test intent; the retired Contour manifests are
  available only in legacy Git history.