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

# Local development on the laptop. Keep the subject exact: possession of any
# other identity in the trust domain must not grant interactive host access.
resource "vault_jwt_auth_backend_role" "local_development" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "local-development"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/dev/panxiao81"
  }

  # local-development grants normal KV v2 read/write under kv/k8s and kv/infra,
  # plus short-lived SSH certificate signing.
  # certificate signing; spire-poc only permits lookup and revocation of the
  # caller's own short-lived Bao token.
  token_policies = [
    vault_policy.local_development.name,
    vault_policy.spire_poc.name,
  ]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Every repository publishes TechDocs from a job named `techdocs` through
# panxiao81/ci-actions/publish-techdocs. The job key comes from Gitea's trusted
# task payload (gitea-dynamic-runner taskidentity), not from workflow input.
# ponytail: one shared publisher identity, so any of these repositories can
# overwrite another's docs; split into per-repository roles and S3 identities
# once repositories outside this single owner publish docs.
resource "vault_jwt_auth_backend_role" "ci_techdocs_publisher" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-techdocs-publisher"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "glob"
  bound_claims = {
    sub = "spiffe://ddupan.top/ci/panxiao81/*/techdocs"
  }

  token_policies          = [vault_policy.ci_techdocs_publisher.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}
