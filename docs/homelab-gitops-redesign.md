# Homelab GitOps and IaC redesign

Status: **implementation in progress; CI、Flux bootstrap、漂移修复与受控 prune 已验证。**

Started 2026-09-09. This is the durable record of the redesign discussion. It
separates observations, decisions and open work so an assumption cannot silently
become a destructive migration.

## Goals

- Make Git the source of infrastructure intent and the normal path to production.
- Reconcile Kubernetes continuously; gate Terraform and Ansible with plans and approval.
- Adopt existing infrastructure before changing it; avoid recreating VMs or disks.
- Keep recovery possible when k3s, Gitea, OpenBao or the home WAN is unavailable.
- Keep OCI within Always Free allowances except deliberately tiny Object Storage use.

## Observed state

### Local host

The laptop is the single-node k3s host, NFS server and libvirt host. These
persistent libvirt domains were observed on 2026-09-09:

| domain | state | CPU | memory | root disk | network |
|---|---|---:|---:|---|---|
| `dc1` | running | 2 | 2 GiB | `data/vm/dc1` zvol | bridge `br0` |
| `winadmin` | running | 4 | 6 GiB | `data/vm/winadmin` zvol | bridge `br0` |
| `bao1` | running | 1 | 1 GiB | `data/vm/bao1` zvol | bridge `br0` |
| `win2k25` | stopped | 2 | 4 GiB | `data/vm/win2k25` zvol | network `network` |

All four have autostart disabled. The intended values for `dc1`, `winadmin`
and `bao1` mostly agree with live configuration. Current Ansible roles stop
managing a VM once its domain exists. That avoids recreation but cannot report
or reconcile later CPU, memory, NIC or boot drift.

### Kubernetes and delivery

- Kubernetes is a single-node k3s `v1.36.4+k3s1` cluster.
- Helm releases and manifests have historically been applied by hand and are now
  being adopted by Flux one release at a time.
- Flux `v2.9.5` is live. Its internal Gitea source and root Kustomization are
  Ready; `http-echo` proved automatic deployment, drift repair and scoped prune.
- Repository history records External Secrets Operator 2.8.0 as deployed. Five
  `ExternalSecret` resources cover Authelia, Gitea, Cloudflared and SeaweedFS.
  All five reported `SecretSynced=True` during a live check on 2026-09-09.
- Gitea Actions now has one instance-scoped runner in namespace `gitea-actions`.
  Its Helm release is deployed, its Pod is `2/2 Running`, its identity PVC is
  bound, and a sixth `ExternalSecret` delivers the registration token from OpenBao.
- The repository is hosted at `panxiao81/homelab-infra` on the local Gitea
  instance. A one-way off-site mirror is still missing.
- Terraform roots remain per-service and must not be merged.
- The k3s node was `Ready` on 2026-09-09. The Snap-packaged `kubectl` could
  not start because the user systemd session was degraded; `k3s kubectl` with the
  same user kubeconfig reached the API successfully. This is a local client issue,
  not evidence that the cluster is down.
- `docs/cicd.md` remains useful but some inventory statements are stale.

### OCI

Read-only OCI discovery found:

- home region `ap-osaka-1`;
- bucket `oci-k8s-free-tier-tfstate` in the root compartment;
- one approximately 25 KiB object, `terraform.tfstate`, modified 2026-08-15;
- state format 4, Terraform 1.15.8, serial 249;
- state for a VM, VCN, public subnet, Internet Gateway, route table, security
  list and free-tier quota;
- Object Storage versioning is not enabled;
- the source Terraform root was not found locally.

The state is likely authoritative. Its contents are sensitive and must not be
printed or committed. Restore its configuration to a zero-change plan before
considering a public-to-private subnet redesign.

## Agreed architecture

### Control planes

| scope | controller | application model |
|---|---|---|
| Kubernetes | Flux | continuous pull reconciliation after merge |
| Terraform | CI | plan; explicit approval before apply |
| Ansible | CI | check/diff; explicit approval before execution |
| Backstage | none | read-only portal and PR authoring |

Flux was selected over Argo CD for a small cluster whose primary interface
should remain Git and Kubernetes resources. Backstage supplies the unified UI
without becoming another deployment controller.

### CI execution

Most CI uses Gitea Actions for its GitHub Actions compatibility. A persistent
Gitea Runner StatefulSet runs in Kubernetes with Docker-in-Docker and capacity
four; individual job containers are created dynamically. The chart requires a
privileged DinD container in both modes, and rootlesskit is blocked by the node's
AppArmor unprivileged-userns policy, so regular DinD is used instead of weakening
that host-wide policy. The runner is instance-scoped and accepts trusted
repositories and workflows only.

Only explicitly labelled jobs needing privilege, nested virtualization,
amd64-only software or isolation from k3s use an ephemeral Proxmox VM. IaC owns
the PVE template, pool, permissions, network and quotas; the scheduler owns the
short-lived clone/start/run/destroy lifecycle. Ephemeral workers do not enter
Terraform state. OCI A1 may later run OCI plans and external checks.

### Ingress

Envoy Gateway becomes the sole in-cluster L7 routing and policy point:

```text
public client -> Cloudflare edge -> Tunnel -> Envoy -> HTTPRoute -> Service
LAN/tailnet  -> split DNS ----------------> Envoy -> HTTPRoute -> Service
```

Tunnel hostnames currently point directly at Services. Migrate them one by one
only after the matching listener, certificate, HTTPRoute and authorization
policy have been verified. Preserve Host and TLS SNI. Remove the global
`no_tls_verify` after origin verification works. Keep an explicit public
hostname allow-list rather than a wildcard tunnel rule.

### Naming and DNS ownership

AD remains `ad.ddupan.top`; moving it back to the apex would make Samba and
Cloudflare competing authorities.

| namespace/data | owner |
|---|---|
| AD SRV, Kerberos, LDAP and member records | Samba AD DNS |
| infrastructure host A/PTR intent | NetBox, reconciled into Samba |
| application names under `ddupan.top` | Git service declaration |
| public application answers | Cloudflare DNS |
| private answers for the same names | Blocky |
| Kubernetes service discovery | CoreDNS |

Machine and service identity are intentionally distinct: `pve1.ad.ddupan.top`
names one host, while `git.ddupan.top` names a movable service. Split-horizon
DNS necessarily returns two answers; the goal is one human-authored service
intent that drives Cloudflare, Blocky, Gateway API and Backstage.

After validation, Blocky should serve LAN and Tailscale clients. CoreDNS should
forward `ad.ddupan.top` to Samba and application split-DNS queries to Blocky
instead of keeping one template per hostname. Keep the router as secondary DNS
so laptop failure degrades to the public route rather than a household outage.

Samba stays an AD-specific authority. Its current tasks are add-only; a future
reconciler may update and delete only an explicit owned set and must never purge
the zone or touch Samba-generated records.

### Certificates

Browser-facing internal services use Let's Encrypt with Cloudflare DNS-01. A
private DNS answer does not prevent public ACME DNS validation. OpenBao remains
the CA for LDAPS, database TLS, mTLS, SSH and machine identities.

PVE UI/API must not depend on k3s. Keep direct break-glass endpoints at
`pve1/2/3.ad.ddupan.top:8006` and change only the optional pveproxy certificate
from OpenBao ACME to Let's Encrypt DNS-01. Never replace PVE's cluster-internal
`pve-ssl.pem`. Use a dedicated DNS-only Cloudflare token.

### OCI recovery island

The home has no public IP; Tailscale is the management network. The minimal OCI
shape therefore needs no public VM address or Load Balancer:

```text
home -> Tailscale -> private OCI A1 VM
                         |-> NAT Gateway for outbound connectivity
                         `-> Service Gateway -> Object Storage
```

The VM may hold a read-only Git mirror, external probes, recovery docs and
backup verification, but is not a dependency of healthy home services. OCI LB
and free MySQL remain optional for a later interactive backup Forgejo portal.

### Terraform state

- Recover the OCI root before changing backend or network architecture.
- Never initialize an empty replacement with the same state name.
- Take an encrypted independent backup before enabling bucket versioning.
- Test two concurrent operations before relying on OCI S3 `use_lockfile`.
- Gitea 1.27 provides a Terraform State Registry through Terraform HTTP backend,
  including locking and state-version history. Confirm the running Gitea version
  and test backup/restore before adopting it.
- Prefer Gitea State Registry for local roots once validated. Keep the OCI recovery
  root in OCI Object Storage initially so cloud recovery does not depend on the
  home cluster or Gitea.
- Existing SeaweedFS state remains authoritative until each root is migrated
  deliberately; retain encrypted off-site state copies throughout migration.

### Secret delivery

OpenBao is the authority for workload secrets and External Secrets Operator is
the Kubernetes delivery mechanism. Git contains `ClusterSecretStore` and
`ExternalSecret` intent only; ESO materializes ordinary Kubernetes Secrets.

This path already exists: ESO uses its ServiceAccount JWT, the OpenBao role is
bound to that service account and namespace, and policy access is read-only under
`kv/k8s/*`. Before expanding IaC automation, re-verify live reconciliation,
OpenBao snapshot recovery and application behaviour during an OpenBao outage,
then migrate any remaining manually managed Secrets one service at a time.

OpenBao bootstrap, unseal/recovery material and backup credentials require an
offline break-glass path. ESO-generated Secrets are projections, not backups.

## Implementation phases

1. **In progress:** sanitized libvirt/Helm evidence is recorded; the independent
   encrypted OCI state backup is still missing.
2. **In progress:** live OpenBao/ESO delivery is verified; verify recovery and inventory
   remaining manually managed Secrets, then migrate them incrementally.
3. **In progress:** the Gitea remote exists; add a one-way off-site mirror and
   revisit the Terraform State Registry after upgrading beyond Gitea 1.25.5.
4. **Complete:** the reviewed Gitea Runner and Stage 1 CI are live. Flux deploys
   `http-echo`; automatic deployment, replica drift repair and scoped deletion
   were verified. Root prune remains disabled for brownfield safety.
5. **Next:** adopt the existing `gitea-actions` Helm release with the same chart
   `0.1.1` and repository values before attempting an upgrade. Its live
   StatefulSet and Git both use regular DinD, while Helm's stored release values
   still describe the failed rootless attempt. The first Flux reconciliation
   must repair this stored-state drift without changing the live Pod spec.
6. Move Tunnel origins to Envoy and consolidate split DNS through Blocky.
7. Deploy Backstage read-only with Catalog, Kubernetes, Flux and TechDocs.
8. Reconstruct the OCI root to a zero-change plan and add libvirt drift reports.
9. Add dynamic PVE VM workers only when a real job requires one, with TTL cleanup
   and hard concurrency/resource limits first.

## Open decisions

- Primary Git remote and off-site mirror location.
- Running Gitea version, State Registry availability and independent backup path.
- Whether OCI Object Storage passes the concurrent lockfile test.
- Whether the OCI VM should later move from its current public subnet.
- Schema/generator for the Git-owned service declaration.
- Migration order for Helm releases after the `gitea-actions` adoption.
- Whether each local libvirt VM should autostart.
- Which first job genuinely requires a dynamic Proxmox VM.

## Safety invariants

- Imported Terraform roots require a zero-change plan before apply.
- Existing zvols, VM boot disks and OCI boot volumes are protected from deletion.
- No runner image or VM template contains a long-lived credential.
- OpenBao recovery material has an offline break-glass copy; ESO output is never
  treated as the only secret backup.
- Flux deploys Kubernetes; Backstage observes and opens pull requests.
- PVE, OpenBao and Git retain recovery paths independent of k3s.
- No credential or Terraform state content is committed or copied into an issue.
