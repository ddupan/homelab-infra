# Policy bodies live in policies/*.hcl so they stay readable and diffable.
# Exported verbatim from the running instance, so importing produces no diff.
#
# OVERLAP WARNING: ../ansible (role openbao_bootstrap) also writes these — hence
# the "# Ansible managed" header still inside each file. Gate those Ansible tasks
# off before applying, or the two will overwrite each other on alternate runs.
resource "vault_policy" "admin" {
  name   = "admin"
  policy = file("${path.module}/policies/admin.hcl")
}

resource "vault_policy" "ai_agent_ssh" {
  name   = "ai-agent-ssh"
  policy = file("${path.module}/policies/ai-agent-ssh.hcl")
}

resource "vault_policy" "local_development" {
  name   = "local-development"
  policy = file("${path.module}/policies/local-development.hcl")
}

resource "vault_policy" "spire_poc" {
  name   = "spire-poc"
  policy = file("${path.module}/policies/spire-poc.hcl")
}

resource "vault_policy" "snapshot" {
  name   = "snapshot"
  policy = file("${path.module}/policies/snapshot.hcl")
}

# Read-only kv/k8s/* for the External Secrets Operator. Unlike the three above
# this one is NOT also written by Ansible, so there is no overlap to gate off.
resource "vault_policy" "external_secrets" {
  name   = "external-secrets"
  policy = file("${path.module}/policies/external-secrets.hcl")
}

# The sandbox cluster has its own Kubernetes auth backend and a deliberately
# narrower KV view than the homelab ESO instance.
resource "vault_policy" "sandbox_external_secrets" {
  name   = "sandbox-external-secrets"
  policy = file("${path.module}/policies/sandbox-external-secrets.hcl")
}

resource "vault_policy" "ci_techdocs_publisher" {
  name   = "ci-techdocs-publisher"
  policy = file("${path.module}/policies/ci-techdocs-publisher.hcl")
}

resource "vault_policy" "ayatori_dev_controller" {
  name   = "ayatori-dev-controller"
  policy = file("${path.module}/policies/ayatori-dev-controller.hcl")
}

resource "vault_policy" "ayatori_dev_external_secrets" {
  name   = "ayatori-dev-external-secrets"
  policy = file("${path.module}/policies/ayatori-dev-external-secrets.hcl")
}

resource "vault_policy" "ayatori_prod_controller" {
  name   = "ayatori-prod-controller"
  policy = file("${path.module}/policies/ayatori-prod-controller.hcl")
}

resource "vault_policy" "ayatori_prod_external_secrets" {
  name   = "ayatori-prod-external-secrets"
  policy = file("${path.module}/policies/ayatori-prod-external-secrets.hcl")
}

resource "vault_policy" "iam_login_database" {
  name   = "iam-login-database"
  policy = file("${path.module}/policies/iam-login-database.hcl")
}

resource "vault_policy" "ci_terraform_registry_publisher" {
  name   = "ci-terraform-registry-publisher"
  policy = file("${path.module}/policies/ci-terraform-registry-publisher.hcl")
}

resource "vault_policy" "ci_converge" {
  name   = "ci-converge"
  policy = file("${path.module}/policies/ci-converge.hcl")
}

resource "vault_policy" "ai_gateway_keys" {
  name   = "ai-gateway-keys"
  policy = file("${path.module}/policies/ai-gateway-keys.hcl")
}
