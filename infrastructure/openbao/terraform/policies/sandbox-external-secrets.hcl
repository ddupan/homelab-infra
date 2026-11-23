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

# The pod pools' Actions cache-server shared secret (platform/dynamic-runner/cache-server.yaml).
path "kv/data/k8s/gitea-runner-cache-s3" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/gitea-runner-cache-s3" {
  capabilities = ["read"]
}

# ARC's GitHub App (platform/sandbox-arc): org self-hosted runner management only.
path "kv/data/k8s/arc-github-app" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/arc-github-app" {
  capabilities = ["read"]
}
