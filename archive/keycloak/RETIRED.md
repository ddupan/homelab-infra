# Keycloak — RETIRED (2026-07-10)

Keycloak has been **decommissioned** and replaced by **Authelia** as the SSO / OIDC
provider (issuer `https://auth.ddupan.top`, backed by Samba AD via LDAP). See
`../../apps/authelia/`.

## What was removed
- The entire `keycloak` Kubernetes namespace (Deployment, Service, bootstrap Job,
  ConfigMaps, `keycloak-db-secret`) — `kubectl delete namespace keycloak`.
- A **second, abandoned Keycloak** in the `shared-db` namespace (raw manifests:
  `deploy/svc/job/cm keycloak*`) that never became ready (crashlooped ~21.8k times over
  82 days). Deleted the four Keycloak objects only; the `shared-postgresql` CNPG tenant in
  that namespace was left untouched.
- The `idm.ddupan.top` public-hostname route from the cloudflared tunnel ingress
  (`../../infrastructure/cloudflared/terraform/main.tf`). `idm.ddupan.top` now returns HTTP 404.

## Consumers migrated
- **Gitea** — OIDC provider switched from `keycloak` to `authelia`
  (`../../apps/gitea/gitea-values.yaml`, secret `gitea-oidc-secret`). The `panxiao81`
  account was re-linked to the Authelia source by email (`ACCOUNT_LINKING=auto`).

## Leftovers (intentionally not cleaned up)
- **Orphaned tables** in the shared `postgres` database: Keycloak ran against
  `jdbc:postgresql://shared-postgresql.shared-db.svc:5432/postgres` as the
  superuser, creating its tables in that DB's `public` schema. They are inert;
  dropping ~90 tables by hand was judged risky/low-value. Drop them manually if
  you want the DB tidy.
- **DNS**: the `idm.ddupan.top` CNAME still exists at Cloudflare (points at the
  tunnel, so it just hits the 404 catch-all). Remove it in the Cloudflare dash if
  desired; it is not managed by Terraform.

The manifests in this directory are kept for reference only. Safe to delete.
