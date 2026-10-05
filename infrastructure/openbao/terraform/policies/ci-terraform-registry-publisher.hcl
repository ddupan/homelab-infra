# Release jobs of terraform-provider-* repositories: upload builds to the terraform-registry bucket.
# They cannot publish a signed release: SHA256SUMS is signed on the maintainer's YubiKey (scripts/publish).
path "kv/data/k8s/terraform-registry-s3-publisher" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
