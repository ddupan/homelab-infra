# Read only the shared OpenSandbox control-plane API key. The same Bao object is
# consumed by the server in sandbox and, later, by the scheduler in homelab.
path "kv/data/k8s/opensandbox-api" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/opensandbox-api" {
  capabilities = ["read"]
}

# The sandbox dynamic-runner worker's own Gitea runner registration. It no
# longer reads the NATS or homelab scheduler secrets.
path "kv/data/k8s/dynamic-runner-pod-sandbox" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/dynamic-runner-pod-sandbox" {
  capabilities = ["read"]
}
