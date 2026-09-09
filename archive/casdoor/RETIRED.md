# Casdoor — RETIRED (2026-07-10)

Casdoor was an SSO/IdP experiment, evaluated and rejected in favour of **Authelia**
(see `../../apps/authelia/`). Decommissioned:

- Deleted the entire `casdoor` Kubernetes namespace (Helm releases `casdoor` +
  `casdoor-postgresql`, deployment, services, secrets, configmap, in-namespace Postgres).
- Dropped the orphaned `casdoor` database from the shared Postgres (`shared-db`).

It was never publicly routed (no cloudflared/gateway ingress) and had no consumers.
This directory is kept only as a tombstone.
