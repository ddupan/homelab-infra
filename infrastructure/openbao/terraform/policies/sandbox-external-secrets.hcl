# Read only the shared OpenSandbox control-plane API key. The same Bao object is
# consumed by the server in sandbox and, later, by the scheduler in homelab.
path "kv/data/k8s/opensandbox-api" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/opensandbox-api" {
  capabilities = ["read"]
}

# The sandbox dynamic-runner worker joins the homelab scheduler's NATS queue
# and forwards executor updates to Gitea as that runner. Both objects hold
# other fields too; accepted because they are already readable in homelab.
path "kv/data/k8s/nats" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/nats" {
  capabilities = ["read"]
}

path "kv/data/k8s/dynamic-runner" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/dynamic-runner" {
  capabilities = ["read"]
}
