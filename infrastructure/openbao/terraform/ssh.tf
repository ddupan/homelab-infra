# SSH certificate authority for machine/agent access.
# The CA KEYPAIR itself is NOT managed here (see mounts.tf) — only this role,
# which is what actually constrains what a signed cert may do.
resource "vault_ssh_secret_backend_role" "ai_agent" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "ai-agent"
  key_type = "ca"

  allow_user_certificates = true
  default_user            = "ansible"
  allowed_users           = "*"

  # Deliberately short: access is scoped by TTL + principals rather than by
  # source IP, so a leaked cert expires in minutes.
  ttl     = 300 # 5m
  max_ttl = 900 # 15m

  default_extensions = {
    "permit-pty" = ""
  }
}

# Cinc converge from CI (infrastructure/chef/): the executor SSHes to each node as
# root, bootstraps cinc-client and runs the policy. A separate role from ai-agent so
# CI can never sign for any other principal — ai-agent's "*" is acceptable for a
# human-supervised agent, not for anything a pull request can trigger.
resource "vault_ssh_secret_backend_role" "ci_converge" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "ci-converge"
  key_type = "ca"

  allow_user_certificates = true
  default_user            = "root"
  allowed_users           = "root"

  # sshd checks validity only at authentication, so this bounds how long a run may
  # take to *start* its connections, not how long a converge may last.
  ttl     = 1800 # 30m
  max_ttl = 1800

  default_extensions = {
    "permit-pty" = ""
  }
}
