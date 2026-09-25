# 不含秘密读取或管理权限；默认 policy 只用于自身 token 续期等通用能力。
path "sys/metrics" {
  capabilities = ["read"]
}
