# homelab-cookbooks publish job: upload new cookbook versions to the chef-supermarket bucket.
path "kv/data/k8s/chef-supermarket-s3-publisher" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
