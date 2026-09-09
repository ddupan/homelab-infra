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
