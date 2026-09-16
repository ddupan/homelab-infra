# Local development identity. This policy deliberately permits normal KV v2
# reads and writes but excludes soft-delete, metadata deletion, permanent
# version destruction, auth administration, and privileged operations.
path "kv/data/*" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata" {
  capabilities = ["read", "list"]
}

path "kv/metadata/*" {
  capabilities = ["read", "list"]
}

# Sign disposable SSH public keys for short-lived development access.
path "ssh-client-signer/sign/ai-agent" {
  capabilities = ["create", "update"]
}
