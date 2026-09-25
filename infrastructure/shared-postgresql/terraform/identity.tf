# 复用现有 JWT-SVID 验证挂载，独立身份仅授权此服务所需路径。
resource "vault_policy" "postgresql" {
  name   = "homelab-postgresql-provisioner"
  policy = <<-EOT
    path "pki/sign/homelab-pg-prod" { capabilities = ["update"] }
    path "pki/sign/homelab-pg-dev" { capabilities = ["update"] }
    path "pki/sign/homelab-etcd-client" { capabilities = ["update"] }
    path "kv/data/infra/postgresql/prod" { capabilities = ["create", "read", "update"] }
    path "kv/data/infra/postgresql/dev" { capabilities = ["create", "read", "update"] }
    path "kv/metadata/infra/postgresql/prod" { capabilities = ["read"] }
    path "kv/metadata/infra/postgresql/dev" { capabilities = ["read"] }
    path "kv/data/infra/etcd/consumers/patroni-pg-prod" { capabilities = ["read"] }
    path "kv/data/infra/postgresql/ayatori/prod" { capabilities = ["create", "read", "update"] }
    path "kv/data/infra/postgresql/ayatori/dev" { capabilities = ["create", "read", "update"] }
    path "kv/metadata/infra/postgresql/ayatori/prod" { capabilities = ["read"] }
    path "kv/metadata/infra/postgresql/ayatori/dev" { capabilities = ["read"] }
    path "auth/token/lookup-self" { capabilities = ["read"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }
  EOT
}

resource "vault_jwt_auth_backend_role" "postgresql" {
  backend         = "jwt-spire"
  role_name       = "homelab-postgresql"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/dev/panxiao81"
  }
  token_policies          = [vault_policy.postgresql.name]
  token_no_default_policy = true
  token_ttl               = 900
  token_max_ttl           = 900
}
