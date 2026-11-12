# Renovate PR 升级评审（.gitea/workflows/flux-diff.yml 的 upgrade-review job）。只读它自己那一把
# AI 网关 key：key 由 key UI 签发与吊销（apps/ai-gateway/README.md），吊销后这里读到 404，评审停用。
path "kv/data/k8s/ai-gateway-keys/upgrade-agent" {
  capabilities = ["read"]
}
