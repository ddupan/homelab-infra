# Local development identity. Limit normal KV v2 reads and writes to the k8s
# subtree, and exclude soft-delete, metadata deletion, permanent version
# destruction, auth administration, and privileged operations.
path "kv/data/k8s/*" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata/k8s" {
  capabilities = ["read", "list"]
}

path "kv/metadata/k8s/*" {
  capabilities = ["read", "list"]
}

# Future destination for infrastructure secrets migrated from Ansible Vault.
path "kv/data/infra/*" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata/infra" {
  capabilities = ["read", "list"]
}

path "kv/metadata/infra/*" {
  capabilities = ["read", "list"]
}

# Sign disposable SSH public keys for short-lived development access.
path "ssh-client-signer/sign/ai-agent" {
  capabilities = ["create", "update"]
}
