# Ayatori Prod 控制面的 ESO：只读 Prod 实例的专用管理凭据。
path "kv/data/infra/postgresql/ayatori/prod" {
  capabilities = ["read"]
}
