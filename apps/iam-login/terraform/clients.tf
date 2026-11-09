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

# OpenBao's human login through iam-login: the oidc-sso mount. It was added next to the Authelia one (auth/oidc)
# so there was never a moment without a working login; auth/oidc and Authelia are both retired now. Kept whole in
# this root because the client secret is created here: the mount's config can take it from state, with no copy
# through the Ansible vault.
# OpenBao sends PKCE for the code flow and checks the ID token's aud against bound_audiences (= client id).
# AI gateway key UI (apps/ai-gateway/keys-ui.yaml). It sends PKCE, so PKCE stays required.
resource "homelab_oidc_client" "ai_gateway_keys" {
  id            = "ai-gateway-keys"
  name          = "AI 网关 Key"
  redirect_uris = ["https://ai-keys.lab.ddupan.top/callback"]
  scopes        = ["openid", "profile", "groups"]
}

resource "vault_kv_secret_v2" "ai_gateway_keys" {
  mount = "kv"
  name  = "k8s/ai-gateway-keys-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.ai_gateway_keys.id
    client_secret = homelab_oidc_client.ai_gateway_keys.secret
  })
}

resource "homelab_oidc_client" "openbao" {
  id   = "openbao"
  name = "OpenBao"
  redirect_uris = [
    # The web UI builds the callback from the address it is opened at; bao answers to both names (one cert).
    "https://bao.lab.ddupan.top:8200/ui/vault/auth/oidc-sso/oidc/callback", # web UI
    "https://bao.ad.ddupan.top:8200/ui/vault/auth/oidc-sso/oidc/callback",  # web UI, old name
    "http://localhost:8250/oidc/callback",                                  # CLI: bao login -method=oidc -path=oidc-sso
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

  # Listed on the UI's sign-in page, so nobody has to type the mount path.
  tune {
    listing_visibility = "unauth"
  }

  # The vault provider (4.8) reads tune back empty for this resource, so every plan would set it again although
  # it is applied (sys/internal/ui/mounts lists oidc-sso unauthenticated). To change tune, drop this line for
  # that apply.
  lifecycle {
    ignore_changes = [tune]
  }
}

# auth/oidc's admin role (infrastructure/openbao/terraform/auth.tf), granted to platform-admins rather than the
# per-app vault-admins group, which retires with auth/oidc.
resource "vault_jwt_auth_backend_role" "sso_admin" {
  backend   = vault_jwt_auth_backend.sso.path
  role_name = "admin"
  role_type = "oidc"

  user_claim      = "preferred_username"
  bound_audiences = [homelab_oidc_client.openbao.id]
  # Only members of the AD group platform-admins get the admin policy.
  bound_claims = {
    groups = "platform-admins"
  }
  groups_claim = "groups"
  oidc_scopes  = ["profile", "email", "groups"]

  allowed_redirect_uris = homelab_oidc_client.openbao.redirect_uris

  token_policies = ["admin"]
  token_ttl      = 3600
  token_max_ttl  = 0
}

# Incus (infrastructure/incus): the web UI's code flow and the CLI's device grant (incus remote add --auth-type=oidc),
# both without a secret. Incus checks the access token's aud against oidc.audience, and authorizes from its groups
# claim (authorization scriptlet, infrastructure/incus/ansible/group_vars/incus_hosts.yml): who may do what is
# Incus's decision, not this client's. Both names while CLI remotes still point at the ad name; the ad entries go
# when that name is retired (Incus itself checks only oidc.audience, the lab name).
resource "homelab_oidc_client" "incus" {
  id                   = "incus"
  name                 = "Incus"
  redirect_uris        = ["https://incus.lab.ddupan.top/oidc/callback", "https://incus.ad.ddupan.top/oidc/callback"]
  scopes               = ["openid", "offline_access", "groups"]
  public_client        = true
  device_authorization = true
  audiences            = ["https://incus.lab.ddupan.top", "https://incus.ad.ddupan.top"]
}

# artifact-keeper's env-bootstrapped OIDC provider (apps/artifact-keeper/values.yaml). It sends PKCE by default.
resource "homelab_oidc_client" "artifact_keeper" {
  id            = "artifact-keeper"
  name          = "Artifact Keeper"
  redirect_uris = ["https://artifacts.lab.ddupan.top/api/v1/auth/sso/oidc/callback"]
  scopes        = ["openid", "profile", "email", "groups"]
  # Its code exchange sends client_id and secret only in the form (sso.rs), never Basic; with Basic alone
  # registered, iam-login refused the exchange and artifact-keeper reported a missing id_token as a 500.
  token_endpoint_auth_method = "client_secret_post"
}

# zot's web UI login (apps/zot/values.yaml, http.auth.openid). zot sends PKCE only when it has no client
# secret, so with a secret it sends none; it authenticates with client_secret_basic.
resource "homelab_oidc_client" "zot" {
  id            = "zot"
  name          = "zot"
  redirect_uris = ["https://zot.lab.ddupan.top/zot/auth/callback/oidc"]
  scopes        = ["openid", "profile", "email", "groups"]
  pkce_required = false
}

# Read by apps/zot/external-secret.yaml (zot-sso).
resource "vault_kv_secret_v2" "zot" {
  mount = "kv"
  name  = "k8s/zot-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.zot.id
    client_secret = homelab_oidc_client.zot.secret
  })
}

# The gateway's login for the SeaweedFS admin UI (apps/seaweedfs/securitypolicy-admin.yaml). Envoy's oauth2 filter
# sends PKCE. With the endpoints spelled out in the policy (no discovery), Envoy Gateway sends the client secret as
# HTTP Basic. Stated explicitly: the attribute is computed, so dropping it would keep the old value in state.
resource "homelab_oidc_client" "seaweedfs_admin" {
  id                         = "seaweedfs-admin"
  name                       = "SeaweedFS 管理"
  redirect_uris              = ["https://seaweedfs-admin.lab.ddupan.top/oauth2/callback"]
  scopes                     = ["openid", "profile", "groups"]
  token_endpoint_auth_method = "client_secret_basic"
}

# Read by apps/seaweedfs/sso-external-secret.yaml.
resource "vault_kv_secret_v2" "seaweedfs_admin" {
  mount = "kv"
  name  = "k8s/seaweedfs-admin-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.seaweedfs_admin.id
    client_secret = homelab_oidc_client.seaweedfs_admin.secret
  })
}

# Read by apps/artifact-keeper/sso-external-secret.yaml.
resource "vault_kv_secret_v2" "artifact_keeper" {
  mount = "kv"
  name  = "k8s/artifact-keeper-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.artifact_keeper.id
    client_secret = homelab_oidc_client.artifact_keeper.secret
  })
}

# The local development identity, exchanging its JWT-SVID for a token Artifact Keeper's CI OIDC provider accepts
# (apps/artifact-keeper/ci-oidc). Proves the chain end to end before any CI job uses it; its AK mapping grants nothing.
resource "homelab_machine_client" "dev_panxiao81" {
  id        = "dev-panxiao81"
  name      = "本机开发身份"
  spiffe_id = "spiffe://ddupan.top/dev/panxiao81"
  audiences = ["artifact-keeper"]
}

# OpenList's OIDC login (apps/openlist). It calls back to two paths and sends no PKCE. Its SSO settings live in
# its own database, so the secret is pasted into the admin UI from kv/k8s/openlist-sso (apps/openlist/README.md).
resource "homelab_oidc_client" "openlist" {
  id   = "openlist"
  name = "OpenList"
  redirect_uris = [
    "https://openlist.lab.ddupan.top/api/auth/sso_callback?method=get_sso_id",
    "https://openlist.lab.ddupan.top/api/auth/sso_callback?method=sso_get_token",
  ]
  scopes        = ["openid", "profile", "email"]
  pkce_required = false
}

resource "vault_kv_secret_v2" "openlist" {
  mount = "kv"
  name  = "k8s/openlist-sso"
  data_json = jsonencode({
    client_id     = homelab_oidc_client.openlist.id
    client_secret = homelab_oidc_client.openlist.secret
  })
}
