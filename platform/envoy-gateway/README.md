# Envoy Gateway — LAN ingress + Authelia forward-auth

The cluster's HTTP entry point for services on `ad.ddupan.top`, and the enforcement
point for Authelia authentication. Envoy's LoadBalancer holds **192.168.10.127** (k3s
ServiceLB); routing is by `Host` header.

- Chart: `oci://docker.io/envoyproxy/gateway-helm` **v1.5.6**, ns `envoy-gateway-system`
- `gateway.yaml` — `GatewayClass eg` + `Gateway eg` (`:80` plaintext, `:443` wildcard TLS)
- Gateway API **v1.3.0**
- Replaced Contour on 2026-07-25 (see [Why not Contour](#why-not-contour))

## Adding a service

1. an `HTTPRoute` with `parentRefs` → `eg` / `envoy-gateway-system`, `sectionName: https`
2. an A record in `samba_ad_extra_a_records` → `192.168.10.127` (`../../infrastructure/samba-ad`), then
   `ansible-playbook provision-dc.yml --tags dns`
3. **optionally** a `SecurityPolicy` for Authelia forward-auth — see `../../apps/netbox`

No certificate work: the `:443` listener already serves the `*.ad.ddupan.top` wildcard
from `../cert-manager`. Worked example: `../../apps/netbox`.

## Why not Contour

Contour worked as an ingress, but supports **only the gRPC** Envoy ext_authz protocol —
*"Only the Envoy GRPC authorization protocol will be supported"* (Contour 1.33 docs).
Authelia implements the **HTTP** ExtAuthz filter. The two cannot meet, so Authelia
forward-auth was impossible.

That mattered because **NetBox has no SSO group→role mapping** — its group/superuser
mapping is LDAP-only, and the OIDC pipeline can only assign one static group. Without
forward-auth the options were "promote every user by hand" or "drop SSO and use LDAP,
losing 2FA". Envoy Gateway's `SecurityPolicy.extAuth.http` removes the dilemma.

Envoy Gateway was chosen over Traefik because everything already built — Gateway,
HTTPRoute, wildcard cert, DNS — is Gateway API, so only the GatewayClass and controller
changed. Traefik would have meant reverting to `IngressRoute` + `Middleware`.

## Forward-auth: how it fits together

```
browser ──▶ Envoy ──(ext_authz HTTP)──▶ Authelia ──▶ 200 + Remote-* headers
                │                             └──▶ 401 ⇒ 302 to auth.ddupan.top
                └──▶ upstream app (headers attached)
```

Pieces, each in the directory that owns it:

| where | what |
|---|---|
| `../../apps/netbox/securitypolicy.yaml` | `SecurityPolicy` targeting the app's HTTPRoute |
| `../../apps/authelia/referencegrant-extauth.yaml` | lets a SecurityPolicy in another namespace reference the Authelia Service |
| `../../apps/authelia/values.yaml` | `server.endpoints.authz.ext-authz` + an `access_control` rule |
| `../../apps/netbox/networkpolicy.yaml` | stops anything bypassing Envoy to reach the app directly |

### Three details that cost time

- **`headersToBackend` lives under `extAuth.http`, not `extAuth`.** One level up the API
  rejects it: `unknown field "spec.extAuth.headersToBackend"`.
- **`backendRefs.port` is the SERVICE port, not the container port.** The Authelia chart
  publishes `80 → targetPort http (9091)`; using `9091` fails with
  `TCP Port 9091 not found on service authelia/authelia`.
- **Authelia's session cookie is scoped to `ddupan.top`**, which already covers
  `*.ad.ddupan.top` — so SSO works across both without touching the cookie config.

### ⚠ Trust boundary

Apps behind forward-auth trust `Remote-*` headers. Two things make that safe and **both**
must remain true:

1. `headersToBackend` **overrides** any client-supplied value ("coexisting headers will be
   overridden"), so a spoofed `Remote-User` cannot survive the hop through Envoy.
2. A `NetworkPolicy` per app restricts pod ingress to `envoy-gateway-system`, so nothing
   in-cluster can bypass Envoy. k3s enforces NetworkPolicy (kube-router), so this is real.

Verified by test: a pod in `default` sending `Remote-User: admin` to the app Service gets
**connection refused**, while the same request from `envoy-gateway-system` is served.
Also set `failOpen: false` — if Authelia is down, refuse traffic rather than admit
unauthenticated requests to an app whose auth model is "trust the header".

## Install

### Flux 接管状态

现有 release 为 OCI chart/app `v1.5.6`，且没有 user-supplied values。Git 中固定
同一版本并已完成分阶段 Flux HelmRelease 接管。第一阶段确认 Kustomization Ready、
Helm revision 保持为 1，controller/data-plane Pod UID 与入口响应均未变化后，再通过
独立 PR 解除暂停。OCI 类型 HelmRepository 是按需 chart generator，本身不产生
artifact 或 Ready condition；解除暂停后由 HelmRelease 请求并验证 chart。

`GatewayClass eg` 与 `Gateway eg` 随本目录 Kustomization 由 Flux 管理。接管期间保持
`prune: false`；Gateway API 与 Envoy Gateway CRD 使用 `CreateReplace`，延续现有 Helm
所有权且绝不通过删除 CRD 迁移。Gateway 的三个 `certificateRefs` 最初属于
`kubectl-client-side-apply`；首次 reconcile 已由 Flux 默认 SSA `Override` 接管这些在
Git 中声明且值相同的字段，没有改变 listener spec。不得用 `force: true`，它用于
不可变字段失败时删除重建资源。以下命令保留为 break-glass 手工恢复流程。

```bash
# The Gateway API CRDs may already be owned by another tool's field manager (Contour's
# quickstart used client-side apply), which makes Helm fail with
#   "conflict with kubectl-client-side-apply: .spec.versions".
# Transfer ownership WITHOUT deleting the CRDs (deleting them would delete every
# Gateway and HTTPRoute):
helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.5.6 --untar
kubectl apply --server-side --force-conflicts --field-manager=helm \
  -f gateway-helm/crds/gatewayapi-crds.yaml

helm upgrade --install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.5.6 -n envoy-gateway-system --create-namespace

kubectl apply -f envoy-gateway/gateway.yaml
```

Only one LoadBalancer can hold `:80/:443` — k3s ServiceLB uses hostPorts, so a second
one's `svclb-*` DaemonSet sits at `0/1` and the Gateway stays `PROGRAMMED: False` until
the previous controller's Service is gone.

## Verify

```bash
kubectl -n envoy-gateway-system get gateway eg          # PROGRAMMED=True, ADDRESS 192.168.10.127
kubectl -n envoy-gateway-system get pods                # envoy-... 2/2
kubectl -n <ns> get securitypolicy                      # Accepted=True
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.127/    # 404 = serving, no route matched
```

`ss -lntp` shows **nothing** on `:80/:443` even when healthy — ServiceLB forwards via
iptables/NodePort rather than binding. Test with `curl`, not `ss`.

## Outstanding

Contour source manifests were removed from the clean baseline. Live leftovers may
still exist and must be inventoried before deletion; do not infer live state from
the archive cleanup. The legacy Git history retains the retired manifests.
