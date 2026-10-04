# iam-login 在 homelab k3s 的 ESO 身份：只读 Ayatori Prod 交付给它的那一份应用凭据，
# 不读其他租户。路径由 Database UID 确定，见 clusters/ayatori-prod/iam-login.yaml 的 Tenant status。
path "kv/data/ayatori/prod/applications/2665d345-adbe-4f44-9fc7-ef8dd701468e" {
  capabilities = ["read"]
}
