# Ayatori Dev manager：只在 Dev 应用凭据前缀内以 CAS 创建、读取凭据，并在 Delete 回收时
# 删除整条记录；不读取管理凭据，也不触及 Prod 前缀。
path "kv/data/ayatori/dev/applications/*" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata/ayatori/dev/applications/*" {
  capabilities = ["delete"]
}
