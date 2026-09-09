# OIDC auth (human logins via Authelia).
#
# SCOPE NOTE: only the auth MOUNT and the ROLE are managed here. The backend
# CONFIG (auth/oidc/config) is intentionally left to ../ansible because it
# carries `oidc_client_secret`. Terraform cannot read that value back from the
# API, so managing it here would (a) force the plaintext secret into
# terraform.tfstate and (b) produce a perpetual diff. Ansible already holds it
# in an ansible-vault file.
resource "vault_auth_backend" "oidc" {
  type = "oidc"
  path = "oidc"
}

resource "vault_jwt_auth_backend_role" "admin" {
  backend   = vault_auth_backend.oidc.path
  role_name = "admin"
  role_type = "oidc"

  user_claim      = "preferred_username"
  bound_audiences = ["openbao"]
  # Only members of the AD group vault-admins get the admin policy.
  bound_claims = {
    groups = "vault-admins"
  }
  groups_claim = "groups"
  oidc_scopes  = ["profile", "email", "groups"]

  allowed_redirect_uris = [
    "https://bao.ad.ddupan.top:8200/ui/vault/auth/oidc/oidc/callback", # web UI
    "http://localhost:8250/oidc/callback",                             # CLI login
  ]

  token_policies = ["admin"]
  token_ttl      = 3600
  token_max_ttl  = 0
}

# ── Kubernetes auth: the External Secrets Operator ─────────────────────────
# The BACKEND itself (auth/kubernetes/config) is NOT managed here — it needs the
# cluster CA and a long-lived reviewer JWT, which is key material Terraform must
# not hold. That stays in ../ansible (openbao_bootstrap/tasks/auth_kubernetes.yml),
# per the ownership split in CLAUDE.md. A ROLE is pure API config, so it lives here.
#
# This is what makes the operator credential-less: it presents its own
# ServiceAccount JWT, bao verifies it via the cluster's TokenReview API, and
# returns a short-lived token carrying only the external-secrets policy.
resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  backend   = "kubernetes"
  role_name = "external-secrets"

  # Must match serviceAccount.name / namespace in
  # ../../../platform/external-secrets/values.yaml and the serviceAccountRef in
  # ../../../platform/external-secrets/clustersecretstore.yaml.
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]

  token_policies = [vault_policy.external_secrets.name]
  # Short-lived on purpose: ESO re-authenticates as needed, so there is no value
  # in a long TTL and every extra hour is a longer-lived credential in memory.
  token_ttl = 3600
}
