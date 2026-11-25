# Ayatori Dev ayatori-api（ADR-0027 的凭据子资源）：只读 Dev 应用凭据前缀。apiserver 已按 RBAC
# 授权请求者，这里不能创建、修改或删除凭据，也不触及管理凭据与其他环境。
path "kv/data/ayatori/dev/applications/*" {
  capabilities = ["read"]
}
