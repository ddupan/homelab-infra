# Release jobs of terraform-provider-* repositories: upload to the terraform-registry bucket and sign
# SHA256SUMS. Nothing else.
path "kv/data/k8s/terraform-registry-s3-publisher" {
  capabilities = ["read"]
}

path "kv/data/k8s/terraform-registry-signing" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
