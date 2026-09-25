# 指标只读身份；vmagent 的 Bao Agent sidecar 使用 Pod SA 自动登录与续期。
resource "vault_policy" "metrics" {
  name   = "metrics"
  policy = file("${path.module}/policies/metrics.hcl")
}

resource "vault_kubernetes_auth_backend_role" "metrics" {
  backend                          = "kubernetes"
  role_name                        = "metrics"
  bound_service_account_names      = ["vmagent-main"]
  bound_service_account_namespaces = ["monitoring"]
  token_policies                   = [vault_policy.metrics.name]
  token_ttl                        = 900
  token_max_ttl                    = 3600
}
