# NetBox — evaluation deployment

NetBox (IPAM + DCIM) as a candidate **single source of truth for network facts**.
The case for it, the duplication it would remove, and the topology it would model are
in [`CONTEXT.md`](CONTEXT.md) — read that first.

**Status: deployed and populated for evaluation 2026-07-25. Nothing reads from it yet.**
No Ansible role, Terraform config or playbook consumes NetBox data, so deleting this
service breaks nothing (see [Teardown](#teardown)). It *can* generate the config that
matters, verified against the live router — see
[Verdict](#verdict-it-can-generate-the-config-that-matters).

- Chart: `netbox/netbox` **8.3.38** (app **v4.6.5**) — <https://netbox-community.github.io/netbox-chart/>
- URL: **<https://netbox.ad.ddupan.top>** — LAN only, via the shared Envoy Gateway
  (`../../platform/envoy-gateway`) with the `*.ad.ddupan.top` wildcard cert from `../../platform/cert-manager`.
  Deliberately **not** on the cloudflared tunnel: a full inventory of the network is not
  something to publish to the internet.
- Namespace: `netbox`
- Database: dedicated `netbox` role/db on the shared CNPG cluster (`shared-db`)
- Auth: **Authelia forward-auth** at the gateway (not OIDC — see
  [Authentication](#authentication-authelia-forward-auth-not-oidc)); local `admin`
  retained as break-glass

> Exposure moved off the Tailscale ingress on 2026-07-25: no Tailscale client needed, it
> works from any LAN host (including the Windows admin VM), and traffic never leaves the
> LAN. That required adding cert-manager and — to get AD-group→role mapping — replacing
> Contour with Envoy Gateway. See those directories.

## Layout

| file | what |
|---|---|
| `values.yaml` | Helm values — the whole config, heavily commented |
| `secret.yaml` | **gitignored** — the database password (that is all) |
| `securitypolicy.yaml` | Authelia forward-auth at the gateway |
| `networkpolicy.yaml` | blocks bypassing the gateway — part of the trust boundary |
| `secret.example.yaml` | committed template for the above |
| `namespace.yaml` | the `netbox` namespace |
| `terraform/topology.yml` | **the authoritative topology** — git is the source, NetBox the mirror |
| `terraform/{versions,main,variables,outputs}.tf` | Terraform root that applies it |
| `terraform/attach-wireless.py` | the one thing Terraform cannot express (see below) |
| `terraform/gen-imports.py` | one-shot: adopt pre-existing objects into TF state |
| `terraform/.env` | **gitignored** — API token for the helper scripts |
| `generate/vyos-ospf.py` | derives the VyOS OSPF config from NetBox; `--diff` vs the live router |
| `generate/samba-a-records.py` | derives `samba_ad_extra_a_records`; `--diff` vs the live vars |
| `CONTEXT.md` | the evaluation brief (why NetBox, what it would model) |

## Architecture notes worth knowing before you touch it

**Postgres is external, Valkey is bundled.** The shared CNPG cluster gets a dedicated
role+database, same as Authelia and Gitea. Redis is *not* shared because nothing else in
the cluster runs one, and NetBox wants two logical DBs (RQ task queue + caching) to
itself. `postgresql.enabled: false` / `valkey.enabled: true`.

**The Valkey image is pinned by digest, not tag.** Bitnami's public catalog stopped
serving versioned tags in 2025 — versioned images moved to the `bitnamilegacy` repo and
only `latest` remains public, which is why the chart itself ships `tag: latest`. A
floating tag is not acceptable here, so `values.yaml` pins
`valkey.image.digest`. Verified: `docker.io/bitnami/valkey:9.0.1` → *not found*,
`:latest` → pulls (app 9.1.1). **To bump it, resolve the new digest explicitly:**

```bash
sudo k3s ctr images pull docker.io/bitnami/valkey:latest   # prints the manifest digest
```

**How configuration reaches Django.** The chart renders `netbox.yaml` into a ConfigMap and
its `configuration.py` deep-merges that file plus every `*.yaml` under
`/run/config/extra/*/` into the Django settings namespace. That is what `extraConfig[]`
feeds — arbitrary settings keys work, not just the ones the chart models. `extraConfig`
is currently empty; it held the OIDC client config before the move to forward-auth, and
is the hook to reach for if a future setting has no chart value.

**CSRF.** Envoy terminates TLS and forwards plain HTTP, so Django sees an `http://`
request carrying an `https://` Origin. Without `csrf.trustedOrigins` every POST —
including the login form itself — fails CSRF verification. This is the failure that looks
like "login is broken" rather than "config is missing", and it applies behind any
TLS-terminating proxy.

**Exposure is Gateway API, not Ingress.** The chart's native `httpRoute` block attaches to
the shared `eg` Gateway in `envoy-gateway-system`, `sectionName: https`. Because that
listener already serves the `*.ad.ddupan.top` wildcard, this service owns no certificate
of its own — adding the next LAN service is an `HTTPRoute` plus one A record in
`samba_ad_extra_a_records` (`../../infrastructure/samba-ad`), with no Gateway or cert work.

## Authentication: Authelia forward-auth (not OIDC)

Authelia authenticates and enforces 2FA **at the gateway**. By the time a request
reaches NetBox it is already authenticated, and Envoy has attached headers describing
the user. NetBox runs `netbox.authentication.RemoteUserBackend` and reads them.

### Why not OIDC — the reason this design exists

NetBox was originally wired to Authelia over OIDC. It worked, but **NetBox has no SSO
group → role mapping**: `REMOTE_AUTH_SUPERUSER_GROUPS` and
`AUTH_LDAP_USER_FLAGS_BY_GROUP` are **LDAP-only**, and the social-auth pipeline runs only
`user_default_groups_handler`, which assigns one static group and nothing else. So every
SSO user landed as an ordinary member of `sso-users` and had to be promoted **by hand**,
and later AD group changes never propagated.

Header auth fixes exactly that: `REMOTE_AUTH_GROUP_SYNC_ENABLED` re-evaluates group
membership from the `Remote-Groups` header on **every request**, giving the same
declarative AD-group→role pattern Grafana and Proxmox already use. Remove someone from
`netbox-admins` in AD and their NetBox admin is gone immediately.

Getting there required replacing Contour with Envoy Gateway — Contour speaks only gRPC
ext_authz, Authelia only HTTP. See `../../platform/envoy-gateway/README.md`.

### Header mapping (all three defaults are wrong for Authelia)

| NetBox setting | value | why |
|---|---|---|
| `header` | `HTTP_REMOTE_USER` | matches Authelia's `Remote-User` |
| `groupHeader` | `HTTP_REMOTE_GROUPS` | NetBox defaults to `HTTP_REMOTE_USER_GROUP`, which Authelia never sends |
| `groupSeparator` | `,` | Authelia joins groups with a comma; NetBox defaults to `\|`, which would yield **one** group literally named `a,b,c` |
| `userEmail` | `HTTP_REMOTE_EMAIL` | Authelia sends `Remote-Email` |

Authelia has no split given/family name — only `Remote-Name` — so the first/last-name
headers are deliberately left unmapped.

### ⚠ Trust boundary — read before changing anything here

`RemoteUserBackend` trusts the header **unconditionally**; NetBox has no trusted-proxy
allowlist. Two things keep that safe and **both** must stay true:

1. **Envoy overrides the headers.** `headersToBackend` replaces any client-supplied
   `Remote-User` with Authelia's verdict rather than merging it.
2. **`networkpolicy.yaml` blocks bypass.** Without it, any pod could hit
   `netbox.netbox.svc:8080` directly with `Remote-User: admin` and be superuser.

Verified by test: a pod in `default` sending that header gets **connection refused**;
the same request from `envoy-gateway-system` is served. `failOpen: false`, so if Authelia
is down traffic is refused rather than admitted unauthenticated.

Access is further restricted in `authelia/values.yaml` to `group:netbox-admins` —
otherwise any AD account that can pass 2FA would be auto-provisioned a NetBox user.

**Local login remains as break-glass.** `AUTHENTICATION_BACKENDS` appends
`ObjectPermissionBackend`, which subclasses Django's `ModelBackend`, so the `admin`
password still works — reachable via `kubectl port-forward`, since the gateway
intercepts everything else.

## Prerequisites (already done)

```bash
# Dedicated Postgres role + database on the shared CNPG cluster
POD=$(kubectl -n shared-db get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n shared-db exec "$POD" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE netbox LOGIN PASSWORD '<see secret.yaml>'" \
  -c "CREATE DATABASE netbox OWNER netbox"
```

There is **no OIDC client** for NetBox — forward-auth needs no client credential. What
must exist instead:

- AD group **`netbox-admins`** (`samba_ad_groups` in `../../infrastructure/samba-ad`), applied with
  `ansible-playbook provision-dc.yml --tags directory,accounts`
- DNS A record **`netbox`** → `192.168.10.127` (`samba_ad_extra_a_records`), applied with
  `ansible-playbook provision-dc.yml --tags dns`
- the `ext-authz` endpoint + access-control rule in `authelia/values.yaml`, and the
  `ReferenceGrant` in `authelia/referencegrant-extauth.yaml`

## Deploy

```bash
helm repo add netbox https://netbox-community.github.io/netbox-chart/ && helm repo update netbox

kubectl apply -f netbox/namespace.yaml -f netbox/secret.yaml

# Authelia: ext-authz endpoint + access-control rule + cross-namespace grant
kubectl apply -f authelia/referencegrant-extauth.yaml
helm upgrade authelia authelia/authelia --version 0.11.6 -n authelia -f authelia/values.yaml

kubectl apply -f netbox/networkpolicy.yaml
helm upgrade --install netbox netbox/netbox --version 8.3.38 -n netbox -f netbox/values.yaml
kubectl apply -f netbox/securitypolicy.yaml     # after the HTTPRoute it targets exists
```

> `authelia/values.yaml` is the *only* copy of Authelia's config. Before upgrading it,
> confirm it still matches the live release — `helm get values authelia -n authelia -o yaml`
> and compare **structurally** (parse both to YAML and diff keys); a textual diff is
> useless because `helm get values` sorts keys and strips comments.


## Verify

```bash
kubectl -n netbox rollout status deploy/netbox deploy/netbox-worker
kubectl -n netbox get pods,pvc,httproute,securitypolicy

# Unauthenticated request must be intercepted: 302 -> auth.ddupan.top
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://netbox.ad.ddupan.top/

# Trust boundary: this MUST fail (connection refused)
kubectl run spoof -n default --image=busybox:1.38.0 --restart=Never --rm -i -- \
  wget -q -T 8 -O- --header='Remote-User: admin' http://netbox.netbox.svc.cluster.local/

# Local admin password (break-glass)
kubectl -n netbox get secret netbox-superuser -o jsonpath='{.data.password}' | base64 -d

# API reachable + DB migrated
kubectl -n netbox exec deploy/netbox -- curl -sf localhost:8080/api/status/ | head -c 400
```

Then browse <https://netbox.ad.ddupan.top>. Authelia intercepts, you authenticate with
2FA, and NetBox provisions the user on arrival — **already a superuser**, because
`netbox-admins` is in `REMOTE_AUTH_SUPERUSER_GROUPS`. No manual promotion step.

## Two API gotchas that will bite integrations

**Forward-auth blocks the API unless you carve it out.** Authelia intercepts every
request, including API calls carrying a valid NetBox token — it has no idea what a NetBox
token is, sees no session cookie, and 302s the caller to the login portal. Fixed with a
`bypass` rule for `^/api/` and `^/graphql/` in `authelia/values.yaml`, which must come
**before** the `two_factor` rule (Authelia is first-match-wins). This is not
unauthenticated access: NetBox's own token auth still gates those paths and an anonymous
call returns 403. Verified: token → 200, no token → 403, browser → 302.

**`Prefix.site` is silently ignored on NetBox 4.2+.** It was replaced by a generic scope
(`scope_type`/`scope_id`). Posting `site` returns **200 with the field dropped** — no
error — so a seed script looks like it worked while every prefix ends up unscoped, and an
idempotency check then re-patches forever. `VLAN` still uses `site`, so the two are
inconsistent. This is what made the first `seed.py` run non-idempotent.

## API tokens: `superuser.apiToken` is a dead value on NetBox 4.6

The chart still has a `superuser.apiToken` value (defaulting to a random UUID) and stores
it in the `netbox-superuser` Secret, but **no token is created** — verified:
`Token.objects.count()` was 0 after a clean bootstrap, and using that value returns
`403 {"detail":"Invalid v1 token"}`.

NetBox 4.5 introduced v2 tokens, which are stored only as a salted HMAC digest keyed by
`API_TOKEN_PEPPERS` and are the default for new tokens. Legacy v1 tokens (plaintext,
`Token <value>` header) are deprecated and go away in v5.0. So the secret's `api_token`
key should be treated as **stale, not a credential**.

Mint a real one in the UI, or from the CLI — note the plaintext is available only at
creation, and the header prefix is `Bearer nbt_<key>.`:

```bash
kubectl -n netbox exec deploy/netbox -c netbox -- /opt/netbox/venv/bin/python \
  /opt/netbox/netbox/manage.py shell -c "
from users.models import Token, User
t = Token(user=User.objects.get(username='admin'), description='automation')
t.save()
print(t.get_auth_header_prefix() + t.token)"
```

This matters for the evaluation: any generation/sync tooling (§4 of `CONTEXT.md`)
authenticates this way, and `API_TOKEN_PEPPERS` becomes state that must survive — the
chart auto-generates pepper `1` and preserves it across upgrades via a `lookup`, so
**never clear that Secret or every issued token dies.**

**v2 tokens do NOT break the ecosystem** — an earlier version of this file claimed they
did; that was wrong and is corrected here. NetBox dispatches on the token *value* (an
`nbt_` prefix means v2), **not** the header scheme, so the same v2 token is accepted as
both `Authorization: Bearer <tok>` and `Authorization: Token <tok>` — verified, both 200.
The `"Invalid v1 token"` 403 above happens because the chart's UUID is not a token at all,
not because of the scheme. Tested working against this instance with a v2 token:

| integration | version | result |
|---|---|---|
| `netbox.netbox` modules (write) | 3.23.0 | ✅ created an object |
| `netbox.netbox.nb_inventory` (read) | 3.23.0 | ✅ grouped devices by role (needs `pytz`) |
| `e-breuninger/netbox` Terraform provider | **5.7.0** | ✅ read live prefix data |

Two traps when wiring them up:
- The Terraform provider's `server_url` must be the **base URL without `/api`**; passing
  `.../api` yields a confusing go-openapi error
  (`... is not supported by the TextConsumer`). Provider **v4.x fails against NetBox 4.6**
  regardless — pin `~> 5.0`.
- `nb_inventory` needs `pytz` in the Ansible environment
  (`uv tool install ansible-core --with ansible --with paramiko --with pytz`), and the
  plugin must be enabled (`enable_plugins = netbox.netbox.nb_inventory`).

## Known caveats

- **Reaching NetBox no longer needs the WAN, but logging in still does.**
  `netbox.ad.ddupan.top` is resolved by the DC and served on the LAN. However
  `auth.ddupan.top` resolves publicly and routes back in through the cloudflared tunnel,
  so the OIDC round-trip still crosses the flaky ISP link (`CONTEXT.md` §6) — the same
  exposure Grafana has. The local `admin` account is the fallback when the WAN is down.
  Closing this means giving Authelia an internal HTTPS name, which changes the **issuer**
  and therefore touches Gitea, Grafana and OpenBao as registered clients — a decision to
  take once for all services, not per service.
- `releaseCheck.url` is blanked so NetBox never blocks a page render on `api.github.com`.
- One k3s node, no HA: `valkey.architecture: standalone`, one web pod, one worker.
- Resource presets (`medium` web / `small` worker) are sized for the laptop's headroom at
  survey time (~4 GiB free), not for throughput.

## Teardown

```bash
helm uninstall netbox -n netbox
kubectl delete ns netbox                     # also drops the media + valkey PVCs
POD=$(kubectl -n shared-db get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n shared-db exec "$POD" -c postgres -- psql -U postgres \
  -c "DROP DATABASE netbox" -c "DROP ROLE netbox"
# then remove the netbox access_control rule from authelia/values.yaml, and drop
# `netbox` from the ReferenceGrant's `from` list in authelia/referencegrant-extauth.yaml
helm upgrade authelia authelia/authelia --version 0.11.6 -n authelia -f authelia/values.yaml
kubectl apply -f authelia/referencegrant-extauth.yaml
```

The `netbox-admins` AD group and the `netbox` A record stay in `../../infrastructure/samba-ad` unless you
remove them there too; both are harmless if left.

## Data model

`terraform/topology.yml` holds the §3 topology; the Terraform root reads it with
`yamldecode` and applies it. **Direction is git → NetBox**: the YAML is authoritative,
NetBox is a derived mirror. That settles `CONTEXT.md` §4 the way the rest of the repo
works — a UI you must click to change routing would be a regression.

Terraform (not a script) because of the repo's own boundary — *Terraform owns API-level
configuration* (`../../infrastructure/openbao/terraform` is the precedent) — and because it brings the one
thing the previous hand-rolled `seed.py` could never do: **deletion**. Remove an entry from
the YAML and `terraform apply` removes the object. `plan` doubles as a drift report.

```bash
cd netbox/terraform
export TF_VAR_netbox_token=...        # or terraform.tfvars
terraform init
terraform plan -parallelism=2         # see below re: parallelism
terraform apply -parallelism=2
uv run --with requests --with pyyaml python attach-wireless.py
```

Acceptance test, same spirit as the Ansible here:
`No changes. Your infrastructure matches the configuration.`

### Adopting an already-populated NetBox

`gen-imports.py` writes `imports.tf` from the live API so Terraform **adopts** existing
objects instead of failing on uniqueness. It reads the same `topology.yml`, so resource
addresses and `for_each` keys line up by construction. One-shot — delete `imports.tf` after
the first successful apply.

`netbox_device_primary_ip` is deliberately **not** imported: the provider has no importable
object at the device ID. Letting Terraform "create" it just re-PATCHes `primary_ip4` to the
value it already holds.

### ⚠ Terraform cannot do the Wi-Fi wiring

`netbox_device_interface` has **no `rf_role` and no `wireless_lans`** attribute — checked
against the provider schema — and `netbox.netbox`'s module has the identical gap. So
neither official tool can attach an SSID to a radio. `attach-wireless.py` does that last
mile from the same `topology.yml`; it is idempotent and has a `--check` mode. If a future
provider release adds those attributes, delete it and fold the fields into `main.tf`.

### Four things that cost time here

- **Pin the provider `~> 5.0`.** v4.3.1 fails against NetBox 4.6 at configure time.
- **`server_url` must NOT include `/api`** — same misleading go-openapi error if it does.
- **`-parallelism=2`.** At the default 10 the single NetBox pod times out reads
  (`context deadline exceeded`) during import.
- **Pin NetBox's own defaults or fight them forever.** The provider defaults
  `vm_role`/`is_full_depth` opposite to NetBox, and a VM's `site_id` is *derived from its
  cluster* — leave any of them unset and every plan shows phantom changes.

Loaded: 1 site · 6 prefixes (+roles) · 2 VLANs in group `lab` · the DHCP pool as an
IPRange · 3 wireless LANs · 7 devices · 4 VMs in 2 clusters · interfaces with addresses,
MACs and primary IPs.

Hardware fields (model, serial, CPU/RAM) are **read from `dmidecode`**, not guessed — that
corrected three earlier assumptions: pve1 is a NUC6i3**SYB** board with an i3-6100**U**
(and reports a *blank* system serial, because the OEM never programmed DMI), and pve2/pve3
are Lenovo machine-type `10VGCTO1WW`. NetBox has no native CPU/RAM field for Devices (only
VMs get `vcpus`/`memory`), so that detail lives in `comments`; custom fields would be the
right answer if it ever needs to be queryable.

Two modelling choices worth knowing:

- **The laptop's Broadcom BCM4360 is an `inventory_item`, not an interface.** `b43`/`bcma`
  claim the PCI device but cannot drive BCM4360 (it needs proprietary `broadcom-sta`/`wl`
  with those modules blacklisted), so there is no netdev — an Interface would imply a
  capability the OS does not have.
- **`ap-buffalo` was identified, not assumed**: MAC OUI `d4:2c:46` = BUFFALO.INC, model
  `WSR-1800AX4S` from its login page, and Buffalo's factory SSID suffix `07B0` matches the
  tail of that same MAC.

### ⚠ Two things the data now surfaces

1. **`ap-buffalo` holds `192.168.10.10` — the first address of the DHCP pool** (`.10`–`.250`).
   Either it is a lease that can move, or a static overlapping the pool. Fix by moving the
   AP below `.10` or starting the pool at `.11`; NetBox shows the collision but cannot
   resolve it.
2. **Objects created before the Terraform conversion are not in state**, so Terraform will
   not reconcile them: the guessed device types (`nuc6i3syh`, `thinkcentre-mini`,
   `Laptop`) and the `Generic` manufacturer are orphans needing one manual prune. Anything
   added *since* is managed — removing it from `topology.yml` now deletes it, which is
   exactly what the old `seed.py` could not do.

### Wi-Fi

Three SSIDs off one AP, all bridged **untagged onto the flat LAN** (no `vlan` set) — the
Wi-Fi is not a separate segment; clients get an IX DHCP lease like anything else.

| SSID | radio | auth |
|---|---|---|
| `Buffalo-A-07B0-WPA3` | 5 GHz | WPA3-SAE |
| `Buffalo-A-07B0` | 5 GHz | WPA2-PSK (compat) |
| `Buffalo-G-07B0` | 2.4 GHz | WPA2-PSK |

**NetBox cannot express WPA3.** `auth_type` offers only
`open`/`wep`/`wpa-personal`/`wpa-enterprise`, so WPA3-SAE and WPA2-PSK both store as
`wpa-personal` and the real difference survives only in the description.

`auth_psk` is deliberately empty — NetBox *can* hold the passphrase, but the house Wi-Fi
key does not belong in a system whose backup story is untested when OpenBao is right there.

## Verdict: it can generate the config that matters

`CONTEXT.md` §8 step 5 named the one genuinely error-prone duplication — the VyOS
`area 0 network` list plus interface addresses, where forgetting a line is *silent*
(the subnet exists, has a gateway, and is unreachable from anywhere else).

`generate/vyos-ospf.py` derives it from NetBox and diffs against the live router:

```
$ uv run --with requests python netbox/generate/vyos-ospf.py --diff
matched=8 generated_only=0 live_only=0
```

**Exact match, zero drift.** The derivation rules are the valuable part:

| output | rule |
|---|---|
| interface addresses | every IP assigned to a `vyos-rtr` interface |
| `area 0 network` | every prefix the router **has an interface in** |
| `passive` | interfaces whose prefix has role `sdn` |

The second rule was wrong on the first attempt and the diff caught it. "The SDN prefixes"
omits `192.168.10.0/24` — but the LAN must be in area 0 or VyOS forms no adjacency with
the IX or the laptop and advertises nothing at all. Deriving from *where the router
actually has an address* yields the LAN for free and cannot forget a future VNet, which
is precisely the failure mode NetBox is supposed to prevent.

### Second consumer: AD DNS records (CONTEXT.md §4 item 3)

`generate/samba-a-records.py` derives `samba_ad_extra_a_records` from NetBox and diffs the
hand-written list in `../../infrastructure/samba-ad`:

```
in both=5  netbox only=3  vars.yml only=1
```

**Which** hosts get a record is intent, not a derived fact — domain-joined machines
self-register, so "every IP in the LAN prefix" would be wrong. The selector is NetBox's
native `dns_name` field on the IP address; set it and the host gets a record.

The diff paid for itself immediately: it found **`retrolab` (10.60.0.10) had a live AD DNS
record but was missing from NetBox entirely** — verified up and now modelled. That is the
duplication-detection the whole exercise is meant to provide.

Out of scope by design: service/ingress names like `netbox.ad.ddupan.top`, which point at
the k3s gateway rather than a host. Several such names share one address and `dns_name` is
single-valued per IP, so they stay hand-managed. This tool owns **host** records only.

**So it earns its place on this one case.** Honest caveats before adopting further:

- **This is one generator against one router.** The other consumers in `CONTEXT.md` §4
  (the PVE SDN VNet list, `samba_ad_extra_a_records`, `nb_inventory`) are unproven.
- **NetBox demands ceremony.** Recording "pve1 is 192.168.10.4" first requires a
  manufacturer, a device type, a device role and a site. For ~10 hosts that is real
  overhead the YAML does not have.
- **Nothing consumes it yet.** Until a role actually reads from NetBox, this is a second
  copy of the truth — the very duplication it is meant to remove. The next real step is
  wiring `generate/vyos-ospf.py` into `proxmox/ansible/roles/vyos_router` so the template
  has one source, not two.
