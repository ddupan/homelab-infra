# Authelia — SSO over Samba AD

Authelia is the web SSO layer on top of the Samba AD DC (`../../infrastructure/samba-ad/`): it authenticates
users against **AD over LDAPS** and provides an auth portal + (round 2) an OIDC provider.
Deployed via the **official Helm chart**; config-as-code lives in `values.yaml`.

- Chart: `authelia/authelia` (app 4.39.20)
- Exposure: **cloudflared** → `auth.ddupan.top` → `authelia.authelia.svc:9091`
  (the chart's own ingress is disabled; see `../../infrastructure/cloudflared/cloudflared.yaml`)
- Identity: LDAPS to the DC (`ldaps://192.168.10.5:636`), bind as `svc-authelia`
- Storage: dedicated `authelia` role/db on `shared-postgresql` (no shared superuser)
- Secrets: chart auto-generates session/JWT keys; `values.yaml` pins the LDAP + DB
  passwords and the storage encryption key (data-at-rest, must stay stable)

## Prerequisites (already done)

- AD service account `svc-authelia` (read-only bind), never-expires — created with
  `samba-tool user create svc-authelia ... ; samba-tool user setexpiry svc-authelia --noexpiry`.

## Deploy

These touch the live cluster / shared Postgres, so run them yourself (auto-mode gates
writes to shared infra):

```bash
# 1. dedicated Postgres role + database (run against the CNPG primary)
POD=$(kubectl -n shared-db get pods -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl -n shared-db exec "$POD" -c postgres -- psql -U postgres -v ON_ERROR_STOP=0 \
  -c "CREATE ROLE authelia LOGIN PASSWORD 'Adbdf340cea488a90b4cf07Aa1!'" \
  -c "CREATE DATABASE authelia OWNER authelia"

# 2. install Authelia
helm repo add authelia https://charts.authelia.com && helm repo update authelia
helm upgrade --install authelia authelia/authelia \
  -n authelia --create-namespace -f authelia/values.yaml

# 3. repoint the tunnel (auth.ddupan.top -> authelia) — already edited in the file
kubectl apply -f cloudflared/cloudflared.yaml
kubectl -n cloudflared rollout restart deployment/cloudflared
```

> The DB password above must match `configMap.storage.postgres.password.value` in
> `values.yaml`. If you rotate it, change both.

## Verify

```bash
kubectl -n authelia rollout status deploy/authelia
kubectl -n authelia logs deploy/authelia | grep -iE 'listening|ldap|error'
# then browse https://auth.ddupan.top and log in as an AD user (e.g. administrator)
```

## Round 2 — enable the OIDC provider

Uncomment/add `configMap.identity_providers.oidc` in `values.yaml`: set an
`hmac_secret` (auto-gen ok) and a `jwks` RSA key, then register clients under
`identity_providers.oidc.clients`. Re-run the `helm upgrade` above. Once OIDC is
proven, retire Keycloak (`../keycloak/`) and its `idm.ddupan.top` tunnel entry.

## Notes

- **Contour/Envoy** can't do Authelia forward-auth (gRPC ext_authz only); protect
  apps via **OIDC** or route forward-auth through **Traefik** (`ForwardAuth`).
- Sessions are in-memory (single replica). For HA add `configMap.session.redis`.
- Secrets are inline in `values.yaml` (homelab style, like the other services here);
  move to sops/sealed-secrets if this leaves the homelab.
