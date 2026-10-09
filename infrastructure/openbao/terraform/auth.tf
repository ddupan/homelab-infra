# OIDC auth (human logins via Authelia).
# Being replaced by auth/oidc-sso (iam-login, sso.ddupan.top), declared with its client in
# apps/iam-login/terraform/clients.tf; this mount stays until that one is verified for the UI and the CLI.
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

# A Kubernetes auth mount can validate identities from only the API server it is
# configured against. The sandbox cluster therefore cannot reuse auth/kubernetes,
# whose TokenReview endpoint belongs to homelab.
resource "vault_auth_backend" "sandbox_kubernetes" {
  type = "kubernetes"
  path = "kubernetes-sandbox"
}

resource "vault_kubernetes_auth_backend_config" "sandbox" {
  backend              = vault_auth_backend.sandbox_kubernetes.path
  kubernetes_host      = "https://10.60.0.13:6443"
  kubernetes_ca_cert   = file("${path.module}/certs/sandbox-kubernetes-ca.crt")
  disable_local_ca_jwt = true

  # Deliberately omit token_reviewer_jwt. OpenBao uses the login JWT for
  # TokenReview; the sandbox external-secrets ServiceAccount is bound only to
  # system:auth-delegator and all issued JWTs remain short-lived.
}

resource "vault_kubernetes_auth_backend_role" "sandbox_external_secrets" {
  backend   = vault_auth_backend.sandbox_kubernetes.path
  role_name = "external-secrets"

  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]

  token_policies = [vault_policy.sandbox_external_secrets.name]
  token_ttl      = 3600
}

# Ayatori Dev API-only 控制面（ayatori-dev LXC 上的 k0s）。没有 Pod，登录身份是只用于
# TokenRequest 的 ServiceAccount；与 sandbox 相同不持有 reviewer JWT，两个 SA 绑定
# system:auth-delegator，由登录 JWT 自身调用 TokenReview，因此 JWT 必须带 API audience；
# role 不校验 audience（约束不了什么），身份只由 SA 名称与 namespace 限定。CA 随 k0s PKI 重建时更新。
resource "vault_auth_backend" "ayatori_dev_kubernetes" {
  type = "kubernetes"
  path = "kubernetes-ayatori-dev"
}

resource "vault_kubernetes_auth_backend_config" "ayatori_dev" {
  backend              = vault_auth_backend.ayatori_dev_kubernetes.path
  kubernetes_host      = "https://192.168.10.11:6443"
  kubernetes_ca_cert   = file("${path.module}/certs/ayatori-dev-kubernetes-ca.crt")
  disable_local_ca_jwt = true
}

resource "vault_kubernetes_auth_backend_role" "ayatori_dev_controller" {
  backend   = vault_auth_backend.ayatori_dev_kubernetes.path
  role_name = "ayatori-dev-controller"

  bound_service_account_names      = ["database-openbao-login"]
  bound_service_account_namespaces = ["ayatori-system"]

  token_policies = [vault_policy.ayatori_dev_controller.name]
  token_ttl      = 3600
}

resource "vault_kubernetes_auth_backend_role" "ayatori_dev_external_secrets" {
  backend   = vault_auth_backend.ayatori_dev_kubernetes.path
  role_name = "ayatori-dev-external-secrets"

  bound_service_account_names      = ["external-secrets-openbao-login"]
  bound_service_account_namespaces = ["ayatori-system"]

  token_policies = [vault_policy.ayatori_dev_external_secrets.name]
  token_ttl      = 3600
}

# Ayatori Prod API-only 控制面（ayatori-prod LXC 上的 k0s）。没有 Pod，登录身份是只用于
# TokenRequest 的 ServiceAccount；与 sandbox 相同不持有 reviewer JWT，两个 SA 绑定
# system:auth-delegator，由登录 JWT 自身调用 TokenReview，因此 JWT 必须带 API audience；
# role 不校验 audience（约束不了什么），身份只由 SA 名称与 namespace 限定。CA 随 k0s PKI 重建时更新。
resource "vault_auth_backend" "ayatori_prod_kubernetes" {
  type = "kubernetes"
  path = "kubernetes-ayatori-prod"
}

resource "vault_kubernetes_auth_backend_config" "ayatori_prod" {
  backend              = vault_auth_backend.ayatori_prod_kubernetes.path
  kubernetes_host      = "https://192.168.10.12:6443"
  kubernetes_ca_cert   = file("${path.module}/certs/ayatori-prod-kubernetes-ca.crt")
  disable_local_ca_jwt = true
}

resource "vault_kubernetes_auth_backend_role" "ayatori_prod_controller" {
  backend   = vault_auth_backend.ayatori_prod_kubernetes.path
  role_name = "ayatori-prod-controller"

  bound_service_account_names      = ["database-openbao-login"]
  bound_service_account_namespaces = ["ayatori-system"]

  token_policies = [vault_policy.ayatori_prod_controller.name]
  token_ttl      = 3600
}

resource "vault_kubernetes_auth_backend_role" "ayatori_prod_external_secrets" {
  backend   = vault_auth_backend.ayatori_prod_kubernetes.path
  role_name = "ayatori-prod-external-secrets"

  bound_service_account_names      = ["external-secrets-openbao-login"]
  bound_service_account_namespaces = ["ayatori-system"]

  token_policies = [vault_policy.ayatori_prod_external_secrets.name]
  token_ttl      = 3600
}

# Per-application consumer of an Ayatori credential: bound to iam-login's own SA, so
# the shared external-secrets identity never gains read on tenant credentials.
# Consumed by ../../../apps/iam-login/database.yaml.
resource "vault_kubernetes_auth_backend_role" "iam_login_database" {
  backend   = "kubernetes"
  role_name = "iam-login-database"

  bound_service_account_names      = ["iam-login-database"]
  bound_service_account_namespaces = ["iam-login"]

  token_policies = [vault_policy.iam_login_database.name]
  token_ttl      = 3600
}
