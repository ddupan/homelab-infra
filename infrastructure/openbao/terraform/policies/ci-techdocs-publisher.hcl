# Any techdocs CI job may read the shared TechDocs publisher S3 credentials.
path "kv/data/k8s/techdocs-s3-publisher" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
