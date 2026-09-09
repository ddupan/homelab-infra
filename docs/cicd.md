# CI/CD — what we are building

Status: **design, partly built.** Stage 1 is live. The substrate is undecided.
Started 2026-07-28.

## Goal

Every infrastructure change goes through a pipeline that tests it, **and that
pipeline is the only path to production.**

The second half is the point. Tests you can bypass with `helm upgrade` are not
controls, they are suggestions. The cluster already shows what that looks like:
`authelia` is on revision **14** and `e5renew` on revision **28**, all hand-run.
Nothing is wrong with those releases — but nothing proves anything about them
either, and two of the thirteen deployed Helm releases (`e5renew`, `rustfs`)
have no representation in this repo at all.

So the aim is not "add CI". It is to make the tested path the *only* path, and
to make drift between this repo and reality visible when it happens.

## Current state

| | |
|---|---|
| git | History since 2026-07-28. Four commits, **no remote yet** |
| stage 1 | Live and green — `yamllint`, `ansible-lint`, `terraform fmt`/`validate`. Configs tuned against a real run |
| gitea | 1.25.5, Actions **enabled**, `DEFAULT_ACTIONS_URL=github`. **No runner deployed**, so nothing executes |
| ansible | 33 roles across `infrastructure/proxmox/`, `infrastructure/samba-ad/`, `infrastructure/openbao/` |
| terraform | 4 roots, **local state**, each with **different interactive auth** (`bao login -method=oidc`, `az login`) |
| k8s | ~13 Helm releases, all deployed by hand |
| secrets | 4 config files are gitignored because they embed live secrets, so their contents are **not** version controlled |

## The four stages

**Stage 1 — static. Built.**
`yamllint`, `ansible-lint`, `terraform fmt -check` / `validate -backend=false`.
No cluster, no credentials, no mutation, so it is safe on every push. It already
found a real defect: `infrastructure/proxmox/ansible/` had no `requirements.yml` at all, so a
fresh checkout could not reproduce its collections.

**Stage 2 — server-side dry-run.**
`kubectl apply --dry-run=server`. This is the one that is usually skipped and
matters most here: the cluster runs Gateway API, cert-manager, the
VictoriaMetrics operator and Envoy `SecurityPolicy` CRDs. Offline schema
validation cannot see any of them; server-side dry-run validates against the
real CRDs and admission webhooks. Needs cluster credentials, so it lives in a
separate workflow from stage 1 — a credential problem there must never be able
to block the static gate.

**Stage 3 — ephemeral integration.**
- **Ansible: Molecule.** Its default scenario asserts *idempotence*, which is
  already this repo's written acceptance test ("a second run must report
  `changed=0`"). The standard exists; Molecule just makes something other than a
  human enforce it.
- **Kubernetes: a throwaway `k3d` cluster** — apply everything, assert it
  converges. Catches ordering and cross-resource problems a dry-run cannot.

Realistic coverage: roughly a third of the 33 roles. `vyos_router` (no Python
interpreter), `pve_cluster`, `pve_linstor` and the Windows-join roles need real
hardware or nested VMs on Proxmox. Those stay `--check --diff` against live.

**Stage 4 — deploy and drift.**
Flux reconciles Kubernetes from git. Terraform and Ansible get **scheduled drift
detection**, not auto-apply: `terraform plan -detailed-exitcode` and
`ansible-playbook --check --diff` on a timer, alerting into the VictoriaMetrics
stack that already exists. That is where most of the value is and almost none of
the risk.

## What enforces what

There are only two enforcement mechanisms available, and this lab has both:

- **Kubernetes → reconciliation.** Flux is the only writer. A hand-run
  `helm upgrade` gets reverted on the next interval. Enforcement is free.
- **Ansible and Terraform → credentials.** No reconciler exists for them and one
  should not be invented; nothing stops someone SSHing to a PVE node and running
  `pveum` by hand. The lever is **OpenBao's SSH CA**: if humans hold no standing
  SSH access and the pipeline is the only identity that can get a signed cert,
  the pipeline becomes the only path by credential control. Same shape for
  Terraform — keep the AppRole and the Azure service principal only in CI.

Credential lockdown comes **last**. It is the disruptive step and is only worth
doing once the pipeline is trustworthy. A documented break-glass path must
survive it: the playbooks still have to run by hand from the laptop during an
incident, or enforcement locks you out exactly when you need in.

## Substrate — open

**Requirement:** a light always-on orchestrator with ephemeral workers. Not a VM
or LXC parked idle waiting for work. Something must always listen — that is
inherent to event-driven CI — but it should be a controller, not a pet.

| option | verdict |
|---|---|
| **Woodpecker CI** | **Front-runner.** Kubernetes backend runs each step as a standalone Pod; first-class Gitea (OAuth2 + auto-created webhooks); server + agent, both light; stable. Costs a different pipeline syntax, which for shell-step lint jobs is ~20 lines |
| `act_runner` (Gitea native) | Docker or host execution **only** — no Kubernetes executor. Confirmed in source: `labels.go` has just `SchemeDocker`/`SchemeHost`, and `run_context.go` branches only to `startHostEnvironment` or `startJobContainer`. Cheapest (one pod) but leaves a persistent worker |
| Gitea ARC | Real pod-per-job operator, but **Enterprise Edition only** |
| GARM + `garm-provider-k8s` | Right shape. GARM supports Gitea from 1.24, but latest is **v0.2.0-beta1** and the provider documents GitHub runners only — the Gitea pairing is unverified |
| Write a runner from zero | The protocol (`actions-proto-go`) is approachable; reimplementing execution is not — `act_runner` delegates that to a vendored `nektos/act`. A shim spawning one-shot pods is blocked on ephemeral registration (`go-apps/gitea/gitea#32461`) |

**Where runners run** is a separate axis. Argument for Proxmox: pve1–3 have clean
egress, while the k3s node carries `openvpn-client@naist`, whose 58 split-tunnel
routes blackhole Cloudflare, Fastly and Microsoft ranges whenever the tunnel dies
— and pods inherit the host routing table. CI on the laptop will fail
mid-build in confusing ways every time that happens. Argument against: no GARM
Proxmox provider exists, so ephemeral Proxmox VMs would mean writing one.

## Prerequisites

Blocking, in order:

1. **Externalise secrets.** `apps/gitea/gitea-values.yaml`, `apps/authelia/values.yaml`,
   `infrastructure/cloudflared/cloudflared.yaml` and `litellm-gateway/docker-compose.yml` are
   gitignored because they embed live credentials. GitOps requires the opposite —
   a reconciler can only apply what is in git. OpenBao + External Secrets is the
   natural fit; `openbao_bootstrap/tasks/auth_kubernetes.yml` already exists.
2. **A git remote.** Gitea is the obvious host, but it runs *on* the cluster it
   would deploy, so keep an off-cluster mirror for disaster recovery.
3. **Terraform: shared state.** All four roots use local `*.tfstate`. Any
   pipeline that applies needs shared state — the S3-compatible SeaweedFS/rustfs
   already on the cluster is a candidate, with the caveat that cluster state
   living on the cluster is the same circularity as hosting git there.

**Not a blocker: non-interactive auth.** An earlier draft of this document
called `bao login -method=oidc` and `az login` hard blockers that would widen the
blast radius. That was wrong on both counts.

- **OpenBao** — the Kubernetes auth backend is **already bootstrapped**
  (`infrastructure/openbao/ansible/roles/openbao_bootstrap/tasks/auth_kubernetes.yml`). A CI pod
  authenticates with its ServiceAccount JWT and stores **no credential at all**.
  AppRole is the equivalent for anything running off-cluster.
- **Azure** — the provider supports service principal with a client secret,
  service principal with a **client certificate**, managed identity, and **OIDC
  workload identity federation** (`use_oidc = true` with `oidc_token_file_path`,
  which explicitly covers generic OIDC providers, not just GitHub/ADO).
  HashiCorp's own guidance is to use a service principal or MSI *specifically*
  when running non-interactively in CI, and reserve the Azure CLI for local runs.

It also **narrows** privilege rather than widening it. The current path needs an
`az login` as Global Admin / Privileged Role Admin — because that is what
creating app registrations and granting admin consent requires. A scoped service
principal managing steady state is dramatically less privileged than the human
identity in use today. Same for OpenBao: a per-root AppRole or Kubernetes role
can be scoped to exactly the paths that root owns, whereas an interactive OIDC
admin login is not.

The blast-radius concern in CLAUDE.md is about **merging the roots**, not about
machine identities. Per-root scoped credentials preserve that separation and
reduce privilege at the same time.

The honest caveat is a split, not a blocker: app-registration creation and admin
consent are genuinely high-privilege **bootstrap** operations and should stay
manual. CI should hold an identity that manages steady state only. The cleanest
assembly with what already exists: keep the Azure SP certificate in OpenBao, and
let the CI pod fetch it via Kubernetes auth — so nothing long-lived is stored in
the CI system itself.

## Non-goals

- **High availability.** One node. Nothing to fail over to. GitOps here buys
  drift elimination and rebuild-from-scratch, not uptime.
- **Autoscaling.** Nothing to scale across.
- **Untrusted-workload isolation.** One author. This changes the day it stops
  being true, and the runner's trust model must be revisited then.
- **Terraform or Ansible under a Kubernetes reconciler.** More machinery on the
  single node that is also NFS server, libvirt host and netboot appliance makes
  recovery harder, not easier.
- **Merging the Terraform roots.** Already considered and rejected; see CLAUDE.md.

## Sequencing

1. Externalise secrets — unblocks everything, valuable on its own
2. Capture `e5renew` and `rustfs` into the repo (`helm get values`)
3. Git remote
4. Pick the substrate; stand it up in an isolated namespace
5. Stage 2, then stage 3 on **one** container-friendly role first
6. Flux on one low-stakes namespace (`http-echo` or `marker`)
7. Drift detection for Terraform and Ansible — scoped machine identities
   (OpenBao Kubernetes auth / AppRole, a steady-state Azure SP) land here, and
   are a privilege *reduction* on the admin logins used today
8. Credential lockdown — remove standing human access, with break-glass
   documented. Last, and only once the pipeline has earned trust

Steps 1, 2 and 7 are worth doing even if the CI substrate is never chosen — they
are just "the repo should describe reality".
