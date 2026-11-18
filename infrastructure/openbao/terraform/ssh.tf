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
# the inventory's user, bootstraps cinc-client and runs the policy. A separate role
# from ai-agent so CI can never sign for any other principal — ai-agent's "*" is
# acceptable for a human-supervised agent, not for anything a pull request can trigger.
#
# Principals mirror how Ansible already logs in: root on PVE-built hosts, panxiao81
# (+ NOPASSWD sudo) on Incus instances, whose cloud-init sets disable_root and
# PermitRootLogin no, and ansible (+ NOPASSWD sudo) on dc1, the cloud-init user
# create-dc-vm.yml made. All are root-equivalent, so this widens nothing; the cost is
# that CI logins on those hosts are logged under the non-root name.
resource "vault_ssh_secret_backend_role" "ci_converge" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "ci-converge"
  key_type = "ca"

  allow_user_certificates = true
  default_user            = "root"
  allowed_users           = "root,panxiao81,ansible"

  # sshd checks validity only at authentication, so this bounds how long a run may
  # take to *start* its connections, not how long a converge may last.
  ttl     = 1800 # 30m
  max_ttl = 1800

  default_extensions = {
    "permit-pty" = ""
  }
}

# Ansible host deploy on merge: the login users of the hosts in .gitea/host-deploy.yml — ubuntu on the
# OCI instances, panxiao81 on the laptop, ansible on dc1. Same root-equivalent users ci-converge signs
# for, plus ubuntu. Certs are principal-scoped, not host-scoped, so keep this list to what the allowlist
# actually needs.
resource "vault_ssh_secret_backend_role" "ci_host_deploy" {
  backend  = vault_mount.ssh_client_signer.path
  name     = "ci-host-deploy"
  key_type = "ca"

  allow_user_certificates = true
  default_user            = "ubuntu"
  allowed_users           = "ubuntu,panxiao81,ansible"

  # Bounds when connections may start, not how long a run lasts (as ci-converge).
  ttl     = 1800 # 30m
  max_ttl = 1800

  default_extensions = {
    "permit-pty" = ""
  }
}
