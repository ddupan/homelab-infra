# cert-manager — certificate issuance

Gives LAN services on `ad.ddupan.top` real, auto-renewing X.509 certs. Added 2026-07-25
so NetBox could be served at `https://netbox.ad.ddupan.top` without a hand-issued cert.

- Chart: `jetstack/cert-manager` **v1.21.0**, namespace `cert-manager`
- Two `ClusterIssuer`s, because the homelab has two ACME sources

| issuer | CA | challenge | use it when |
|---|---|---|---|
| `letsencrypt` | Let's Encrypt (public) | DNS-01 via Cloudflare | browsers must trust it with no CA install |
| `bao-acme` | OpenBao internal PKI (`../../infrastructure/openbao`) | HTTP-01 via the shared gateway | no WAN dependency, or the name must stay out of CT logs |

Both were verified `Ready=True` (ACME account registered) on creation.

## The wildcard, and why

`certificate-wildcard-ad.yaml` issues **one** `*.ad.ddupan.top` cert into
`envoy-gateway-system/wildcard-ad-ddupan-top-tls`, which the shared Gateway's `https`
listener serves for every LAN service (`../envoy-gateway/gateway.yaml`).

Consequences worth understanding:

- **Adding a service costs no certificate work.** An `HTTPRoute` plus an A record in
  `samba_ad_extra_a_records` (`../../infrastructure/samba-ad`) is the whole job. No Gateway edit.
- **Internal hostnames stay out of Certificate Transparency logs.** Every Let's Encrypt
  issuance is published publicly; per-host certs would make the internal estate
  enumerable by anyone. One wildcard entry leaks one name.
- The Secret **must** live in `envoy-gateway-system` (the Gateway's namespace): a listener may only reference a
  Secret in the Gateway's own namespace unless a `ReferenceGrant` exists.
- `*.ad.ddupan.top` matches one label only, so the apex `ad.ddupan.top` is listed as an
  explicit second SAN.

## Two traps that will cost you an hour each

**1. DNS-01 self-check must not use the cluster resolver.**
cert-manager polls authoritative nameservers for its `_acme-challenge` TXT record before
asking the CA to validate. In-cluster, `ad.ddupan.top` is routed straight to the Samba AD
DC (`../k3s/coredns-custom.yaml`), which is authoritative internally and knows nothing
about a TXT record written into the **public** Cloudflare zone — so the self-check spins
forever while the record is plainly there. Fixed in `values.yaml`:

```yaml
dns01RecursiveNameservers: "1.1.1.1:53,8.8.8.8:53"
dns01RecursiveNameserversOnly: true
```

**2. DNS-01, not HTTP-01, for Let's Encrypt here.** `ad.ddupan.top` resolves only on the
LAN, so LE cannot reach the host to validate. DNS-01 needs no inbound reachability and is
the only challenge that can issue a wildcard.

## Deploy

### Flux 接管状态

现有 release 为 chart/app `v1.21.0`。Git 中固定同一版本，并用
`suspend: true` 的 HelmRelease 分阶段接管：第一阶段只让 Flux 登记 source、values
与 release 对象，不执行 Helm upgrade。确认 chart artifact、渲染结果和 live workload
均未变化后，再通过独立 PR 解除暂停。

Issuer 与 Certificate 清单随本目录的 Kustomization 由 Flux 管理；现有 Cloudflare
token Secret 只被引用，本次接管不改变其所有权。删除保护期间保持 `prune: false`，且
CRD 同时启用 chart 的 `crds.keep` 与 Flux Helm action 的 `CreateReplace`。

以下命令保留为 break-glass 手工恢复流程；正常变更应提交 Git：

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.0 \
  -n cert-manager --create-namespace -f cert-manager/values.yaml

cp cert-manager/secret.example.yaml cert-manager/secret.yaml   # then fill in the token
kubectl apply -f cert-manager/secret.yaml
kubectl apply -f cert-manager/clusterissuer-letsencrypt.yaml \
               -f cert-manager/clusterissuer-bao-acme.yaml
kubectl apply -f cert-manager/certificate-wildcard-ad.yaml
```

The Cloudflare token is the same one `cloudflared/terraform` uses. Extract it with:

```bash
sed -nE 's/^[[:space:]]*cloudflare_api_token[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' \
  cloudflared/terraform/terraform.tfvars
```

> A naive `cut -d= -f2` also swallows the trailing comment on that line and yields a
> 126-character "token" that fails with `Invalid format for Authorization header`.

The Secret must be in the **cert-manager** namespace — a ClusterIssuer resolves solver
Secret refs where cert-manager runs, not where the Certificate lives.

## ⚠ Token scope

That token carries **Account·Cloudflare Tunnel:Edit** as well as Zone·DNS:Edit, so
anything able to read the Secret could rewrite tunnel routing, not just DNS. Reusing it
was a deliberate call to avoid blocking; minting a token scoped to Zone·DNS:Edit on
`ddupan.top` and swapping it in is a clean, self-contained follow-up.

## Verify

```bash
kubectl get clusterissuer                                   # both Ready=True
kubectl -n envoy-gateway-system get certificate              # wildcard Ready=True
kubectl -n envoy-gateway-system get order,challenge          # empty once issued

kubectl -n envoy-gateway-system get secret wildcard-ad-ddupan-top-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -enddate
```

Renewal is automatic at 30 days remaining (`renewBefore: 720h`), a deliberately wide
window so a flaky WAN has many chances to retry.

## Using the internal CA instead

Point a Certificate at `bao-acme` when CT-log exposure or WAN dependence matters:

```yaml
issuerRef:
  name: bao-acme
  kind: ClusterIssuer
```

Issuance is capped by `default_directory_policy = role:bao-server`
(`../../infrastructure/openbao/terraform/pki.tf`), which permits `ad.ddupan.top` subdomains only. Clients
need the internal CA in their trust store — already true for the PVE nodes, the DC and
Authelia, generally **not** for a browser.
