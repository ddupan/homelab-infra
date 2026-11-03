# Cinc converge CI jobs: sign a root SSH cert for the nodes they converge — nothing else.
path "ssh-client-signer/sign/ci-converge" {
  capabilities = ["create", "update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
