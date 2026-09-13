# Intentionally grants no secret access. This policy proves that an exact
# SPIFFE ID can exchange a JWT-SVID for a bounded OpenBao token and inspect or
# revoke only that token.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
