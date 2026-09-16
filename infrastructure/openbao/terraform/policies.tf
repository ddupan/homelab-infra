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
