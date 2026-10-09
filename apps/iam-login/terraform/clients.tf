# OIDC clients of iam-login (sso.ddupan.top). The client API is the only way clients are managed; the
# /console UI is for looking and for emergencies, and changes made there show up as drift here.

# Gitea's `sso` login source (../../gitea/gitea-values.yaml). Gitea 1.27 sends neither PKCE nor a nonce.
# Adopted as registered by hand on 2026-10-04: its secret cannot be read back, so `secret` stays null in
# state and kv/k8s/gitea-sso keeps the hand-stored value. Setting secret_rotation would issue a new one,
# invalidate the old immediately, and need it written to kv/k8s/gitea-sso plus a Gitea restart.
import {
  to = homelab_oidc_client.gitea
  id = "gitea"
}

resource "homelab_oidc_client" "gitea" {
  id            = "gitea"
  name          = "Gitea"
  redirect_uris = ["https://git.ddupan.top/user/oauth2/sso/callback"]
  scopes        = ["openid", "profile", "email", "groups"]
  pkce_required = false
}

# Grafana's generic_oauth (platform/observability/grafana/values.yaml).
resource "homelab_oidc_client" "grafana" {
  id            = "grafana"
  name          = "Grafana"
  redirect_uris = ["https://grafana.lab.ddupan.top/login/generic_oauth"]
  scopes        = ["openid", "profile", "email", "groups"]
}

# Read by platform/observability/grafana/sso-external-secret.yaml.
resource "vault_kv_secret_v2" "grafana" {
  mount = "kv"
  name  = "k8s/grafana-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.grafana.id
    client_secret = homelab_oidc_client.grafana.secret
  })
}

# Backstage's oidc provider (panxiao81/backstage). It sends no PKCE (plugin-auth-backend-module-oidc-provider),
# so PKCE is off as for Gitea; it authenticates with client_secret_basic and resolves users by preferred_username.
resource "homelab_oidc_client" "backstage" {
  id            = "backstage"
  name          = "Backstage"
  redirect_uris = ["https://backstage.lab.ddupan.top/api/auth/oidc/handler/frame"]
  # The frontend asks for groups too (packages/app/src/App.tsx), though nothing uses them yet.
  scopes        = ["openid", "profile", "email", "groups"]
  pkce_required = false
}

# Read by apps/backstage/sso-external-secret.yaml.
resource "vault_kv_secret_v2" "backstage" {
  mount = "kv"
  name  = "k8s/backstage-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.backstage.id
    client_secret = homelab_oidc_client.backstage.secret
  })
}

# OpenBao's human login through iam-login: a second OIDC mount, oidc-sso, next to the Authelia one (auth/oidc,
# infrastructure/openbao) until it is verified, so there is never a moment without a working login. Kept whole in
# this root because the client secret is created here: the mount's config can take it from state, with no copy
# through the Ansible vault (which is why auth/oidc's config lives in infrastructure/openbao/ansible).
# OpenBao sends PKCE for the code flow and checks the ID token's aud against bound_audiences (= client id).
resource "homelab_oidc_client" "openbao" {
  id   = "openbao"
  name = "OpenBao"
  redirect_uris = [
    "https://bao.ad.ddupan.top:8200/ui/vault/auth/oidc-sso/oidc/callback", # web UI
    "http://localhost:8250/oidc/callback",                                 # CLI: bao login -method=oidc -path=oidc-sso
  ]
  scopes = ["openid", "profile", "email", "groups"]
}

resource "vault_jwt_auth_backend" "sso" {
  type               = "oidc"
  path               = "oidc-sso"
  description        = "Human login through iam-login (sso.ddupan.top)"
  oidc_discovery_url = "https://sso.ddupan.top"
  oidc_client_id     = homelab_oidc_client.openbao.id
  oidc_client_secret = homelab_oidc_client.openbao.secret
  # A literal, not a reference: the role needs the mount to exist first.
  default_role = "admin"
}

# Same conditions as auth/oidc's admin role (infrastructure/openbao/terraform/auth.tf).
resource "vault_jwt_auth_backend_role" "sso_admin" {
  backend   = vault_jwt_auth_backend.sso.path
  role_name = "admin"
  role_type = "oidc"

  user_claim      = "preferred_username"
  bound_audiences = [homelab_oidc_client.openbao.id]
  # Only members of the AD group vault-admins get the admin policy.
  bound_claims = {
    groups = "vault-admins"
  }
  groups_claim = "groups"
  oidc_scopes  = ["profile", "email", "groups"]

  allowed_redirect_uris = homelab_oidc_client.openbao.redirect_uris

  token_policies = ["admin"]
  token_ttl      = 3600
  token_max_ttl  = 0
}
