# homelab-infra

Infrastructure and service configuration for the homelab. Git is the source of
intent; the live estate is being adopted gradually, so a file being present does
not yet imply that Flux or CI owns the corresponding resource.

## Layout

| directory | purpose |
|---|---|
| `clusters/homelab/` | Flux composition and cluster-specific reconciliation entrypoint |
| `platform/` | cluster-wide controllers, ingress, storage and observability |
| `apps/` | user-facing and supporting applications |
| `infrastructure/` | Proxmox, local hosts/VMs, identity, secrets, Cloudflare and OCI |
| `archive/` | retired implementations retained for operational history |
| `docs/` | architecture decisions, migration plans and runbooks |

Each component remains independently deployable. There is no shared root package
or Terraform root, and service-specific Terraform states must remain isolated.

## Safety

- Treat the homelab as household production.
- Run Terraform plan and Ansible check/diff before mutation.
- Existing resources require a zero-change adoption plan before CI may apply.
- Never commit Terraform plans/states, live Kubernetes Secrets or plaintext keys.
- Kubernetes will be reconciled by Flux; Backstage is a portal, not a deployer.
- Recovery of PVE, OpenBao and Git must not depend on k3s being healthy.

See [the redesign record](docs/homelab-gitops-redesign.md) for the target
architecture and phased migration.
