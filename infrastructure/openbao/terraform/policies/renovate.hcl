# Renovate on oci-arm (infrastructure/oci/ansible/roles/renovate): read its two tokens, then revoke
# its own Bao token.
path "kv/data/k8s/renovate" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
