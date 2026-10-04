# Ayatori Prod manager：只在 Prod 应用凭据前缀内以 CAS 创建、读取凭据，并在 Delete 回收时
# 删除整条记录；不读取管理凭据，也不触及 Dev 前缀。
path "kv/data/ayatori/prod/applications/*" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata/ayatori/prod/applications/*" {
  capabilities = ["delete"]
}
