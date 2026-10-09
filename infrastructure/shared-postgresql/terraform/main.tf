terraform {
  required_version = ">= 1.10"
  required_providers {
    vault = { source = "hashicorp/vault", version = "~> 4.0" }
  }
}
provider "vault" {
  address = "https://bao.ad.ddupan.top:8200"
  # 使用包装器取得的短期 token；它负责执行后撤销，不要求额外创建子 token。
  skip_child_token = true
}
# 只管理新实例的签发角色；不保存 CA 私钥、实例密码或 etcd 账号。
# 允许 ad 与 lab 两个精确名字：lab 是迁移目标（infrastructure/dns/README.md），
# ad 保留到客户端（Ayatori 租户 Secret）不再按它校验为止。
resource "vault_pki_secret_backend_role" "postgresql" {
  for_each                    = toset(["prod", "dev"])
  backend                     = "pki"
  name                        = "homelab-pg-${each.key}"
  allowed_domains             = ["pg-${each.key}.ad.ddupan.top", "pg-${each.key}.lab.ddupan.top"]
  allow_bare_domains          = true
  allow_subdomains            = false
  allow_any_name              = false
  allow_localhost             = false
  allow_wildcard_certificates = false
  allow_ip_sans               = true
  server_flag                 = true
  client_flag                 = false
  key_type                    = "ec"
  key_bits                    = 256
  ttl                         = 5184000
  max_ttl                     = 5184000
}
