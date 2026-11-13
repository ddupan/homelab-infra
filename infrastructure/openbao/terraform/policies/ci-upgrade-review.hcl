# Renovate PR 升级评审（.gitea/workflows/flux-diff.yml 的 upgrade-review job）。只读它自己那一把
# AI 网关 key：key 由 key UI 签发与吊销（apps/ai-gateway/README.md），吊销后这里读到 404，评审停用。
path "kv/data/k8s/ai-gateway-keys/upgrade-agent" {
  capabilities = ["read"]
}

# spiffe-openbao-login 在 job 结束时撤销自己的 token；缺这条会 403，token 只能等 TTL 过期。
path "auth/token/revoke-self" {
  capabilities = ["update"]
}

# 评审的 trace 经 otlp.lab.ddupan.top 发到 collector 的 4319（bearer token，只进 traces 管道）。
path "kv/data/k8s/otel-collector" {
  capabilities = ["read"]
}

# 评审评论以 Bot 账号 upgrade-agent 发出（.gitea/upgrade-review/README.md 的 Bootstrap）。
path "kv/data/k8s/upgrade-agent" {
  capabilities = ["read"]
}
