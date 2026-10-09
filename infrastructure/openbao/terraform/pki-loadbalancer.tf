# Ayatori LoadBalancer 管理 API 的客户端 CA，每个环境一个独立的根。LB 主机上的
# dataplaneapi 与 gobgpd 只能"信任某个 CA"，无法按 CN 或 SPIFFE ID 授权：凡链到该根的
# 客户端证书都能改写 HAProxy 配置、经 gobgpd 向 VyOS 宣告任意前缀。因此：
#   - 不能挂在 pki/ 下（pki/ 签过的任何证书都会成为 LB 管理员）；
#   - 不能 Dev/Prod 共用（Dev 控制面会成为 Prod LB 的管理员）。
# LB 主机的服务端证书走 pki/ 的 ACME（bao-server 角色），不在这里。
# 私钥在 Bao 内生成且不可导出（type = internal）；CA 证书经 /ca/pem 匿名分发给 LB 主机。
locals {
  loadbalancer_environments = toset(["dev", "prod"])
}

resource "vault_mount" "pki_loadbalancer" {
  for_each              = local.loadbalancer_environments
  path                  = "pki-loadbalancer-${each.key}"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10y — 须覆盖根证书自身寿命
}

resource "vault_pki_secret_backend_root_cert" "loadbalancer" {
  for_each    = local.loadbalancer_environments
  backend     = vault_mount.pki_loadbalancer[each.key].path
  type        = "internal"
  common_name = "ddupan homelab Ayatori LoadBalancer ${each.key} client CA"
  ttl         = "315360000"
  key_type    = "ec"
  key_bits    = 256

  lifecycle {
    # 换根 = 该环境所有 LB 主机都要重新信任新 CA；只能有意为之。
    prevent_destroy = true
  }
}

resource "vault_pki_secret_backend_role" "loadbalancer_ayatori" {
  for_each = local.loadbalancer_environments
  backend  = vault_mount.pki_loadbalancer[each.key].path
  name     = "ayatori"

  # 只签客户端证书；CN 仅作审计时辨认，LB 主机不据此授权。
  allowed_domains    = ["ayatori-${each.key}-controller"]
  allow_bare_domains = true
  allow_subdomains   = false
  allow_ip_sans      = false
  server_flag        = false
  client_flag        = true
  key_type           = "ec"
  key_bits           = 256
  # ESO 每天重新签发，controller 热加载；3 天寿命容忍 ESO 或 Bao 中断两天。
  ttl     = 259200 # 3d
  max_ttl = 604800 # 7d
  # 短期证书不入存储，也就无从吊销——过期本身就是撤销机制。
  no_store = true
}

resource "vault_pki_secret_backend_config_urls" "loadbalancer" {
  for_each = local.loadbalancer_environments
  backend  = vault_mount.pki_loadbalancer[each.key].path

  issuing_certificates = ["${var.bao_address}/v1/${vault_mount.pki_loadbalancer[each.key].path}/ca"]
}
