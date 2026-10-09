# Ansible managed
# Broad admin for human OIDC logins (auth/oidc-sso, granted to the platform-admins AD group).
# Homelab-broad on purpose; scope down to specific mounts if you want least privilege.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
