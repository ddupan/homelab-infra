# Workload authentication via SPIFFE JWT-SVIDs. The discovery document and
# JWKS contain public verification material, so this backend carries no secret.
resource "vault_jwt_auth_backend" "spire" {
  path               = "jwt-spire"
  description        = "SPIFFE JWT-SVID workload authentication"
  oidc_discovery_url = "https://spire-oidc.ad.ddupan.top"
  bound_issuer       = "https://spire-oidc.ad.ddupan.top"
}

# First end-to-end identity. Keep the subject exact: this role is deliberately
# not a wildcard escape hatch for every workload in the trust domain.
resource "vault_jwt_auth_backend_role" "spire_poc" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "spire-poc"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/ns/spire-poc/sa/spire-jwt-poc"
  }

  token_policies          = [vault_policy.spire_poc.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}
