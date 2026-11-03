# sandbox Patroni 的部署与每日续签身份：只签 etcd 客户端证书、读自己的 etcd 账号和
# K3s/复制密码。与 homelab-postgresql 分开，sandbox 出问题不牵连 prod 续签。
resource "vault_policy" "sandbox_postgresql" {
  name   = "homelab-sandbox-postgresql"
  policy = <<-EOT
    path "${var.pki_mount}/sign/homelab-etcd-client" { capabilities = ["update"] }
    path "${var.kv_mount}/data/infra/sandbox-postgresql" { capabilities = ["read"] }
    path "auth/token/lookup-self" { capabilities = ["read"] }
    path "auth/token/revoke-self" { capabilities = ["update"] }
  EOT
}

resource "vault_jwt_auth_backend_role" "sandbox_postgresql" {
  backend         = "jwt-spire"
  role_name       = "homelab-sandbox-postgresql"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/dev/panxiao81"
  }
  token_policies = [
    vault_policy.sandbox_postgresql.name,
    vault_policy.etcd_consumer["patroni-pg-sandbox"].name,
  ]
  token_no_default_policy = true
  token_ttl               = 900
  token_max_ttl           = 900
}
