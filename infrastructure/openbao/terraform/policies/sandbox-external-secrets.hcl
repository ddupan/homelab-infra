# Read only the shared OpenSandbox control-plane API key. The same Bao object is
# consumed by the server in sandbox and, later, by the scheduler in homelab.
path "kv/data/k8s/opensandbox-api" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/opensandbox-api" {
  capabilities = ["read"]
}
