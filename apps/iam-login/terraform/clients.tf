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
