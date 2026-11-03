# Envoy Gateway — LAN ingress

The cluster's HTTP entry point for services on `ad.ddupan.top`. Envoy's LoadBalancer
holds **192.168.10.127** (k3s ServiceLB); routing is by `Host` header.

- Chart: `oci://docker.io/envoyproxy/gateway-helm` **v1.5.6**, ns `envoy-gateway-system`
- `gateway.yaml` — `GatewayClass eg` + `Gateway eg` (`:80` plaintext, `:443` wildcard TLS)
- Gateway API **v1.3.0**
- Replaced Contour on 2026-07-25 (see [Why not Contour](#why-not-contour))

## Adding a service

1. an `HTTPRoute` with `parentRefs` → `eg` / `envoy-gateway-system`, `sectionName: https`
2. DNS: attach the route to the `https-lab` listener as well and external-dns publishes
   `<name>.lab.ddupan.top` by itself. Do not add new `ad.ddupan.top` names.
3. **a health probe**: add the service's health endpoint (one that answers `200` without a
   redirect — not `/` if that bounces to a login page) to `lan-https` in
   `../observability/metrics/probes/probes.yaml`. Without it, nothing notices when the route
   or backend breaks, and `LanEndpointDown` has no target. Check it first with the in-cluster
   blackbox:
   `kubectl -n monitoring port-forward svc/blackbox-exporter 9115 &`
   `curl -s 'localhost:9115/probe?module=http_2xx&target=https://<host>/<path>' | grep probe_success`.
   **Removing** a service means deleting its probe line too, or the stale target alerts
   (Hydra, 2026-10-05).
4. **a homepage tile** (if people open it in a browser): add `gethomepage.dev/*`
   annotations to the HTTPRoute — copy one from `../../apps/poweradmin/httproute.yaml`.
   `href` is required in practice: without it Homepage derives the URL from
   `hostnames[0]` and `rules[0].matches[0]`, which is the old `ad` name on most routes
   and crashes on routes with no `matches`. See `../../apps/homepage/README.md`.

No certificate work: the `:443` listener already serves the `*.ad.ddupan.top` wildcard
from `../cert-manager`.

No authentication either: the Gateway has no forward-auth. An app that needs login or
AD-group access control does it itself, as an OIDC client of iam-login
(`../../apps/iam-login/`, `sso.ddupan.top`). The Authelia forward-auth that used to
live here went with Authelia's retirement (2026-10-11).

## Why not Contour

Contour supports **only the gRPC** Envoy ext_authz protocol, while the forward-auth
target at the time (Authelia, since retired) spoke only HTTP ExtAuthz — so the 2026-07-25
switch was made for forward-auth. That reason is gone; Envoy Gateway stays because
everything already built — Gateway, HTTPRoute, wildcard cert, DNS — is Gateway API, and
Traefik would have meant reverting to `IngressRoute` + `Middleware`.

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
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.127/    # 404 = serving, no route matched
```

`ss -lntp` shows **nothing** on `:80/:443` even when healthy — ServiceLB forwards via
iptables/NodePort rather than binding. Test with `curl`, not `ss`.

## Outstanding

Contour source manifests were removed from the clean baseline. Live leftovers may
still exist and must be inventoried before deletion; do not infer live state from
the archive cleanup. The legacy Git history retains the retired manifests.

## 后端 TLS 版本

`EnvoyProxy/eg` 显式允许后端 TLS 1.2–1.3，由 `Gateway/eg` 的
`infrastructure.parametersRef` 引用。Incus 7.5.1 只接受 TLS 1.3；
仅创建 BackendTLSPolicy 时，现有 Envoy 上游默认最高 TLS 1.2，会返回
`TLSV1_ALERT_PROTOCOL_VERSION` 并导致入口 503。此设置保留 TLS 1.2 后端兼容性，
不改变前端 TLS listener、证书和路由；各后端仍需各自的 BackendTLSPolicy。
