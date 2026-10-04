# Incus 客户端专用 CA。Incus 开启 core.trust_ca_certificates 后，凡由 server.ca 签发、
# 未过期的客户端证书都获得完整管理权限（等同 laptop root）——所以它必须是独立的根，
# 绝不能挂在内部 CA 下，否则 pki/ 签过的任何证书都会成为 Incus 管理员。
# 用途只有一个：CI 的 incus Terraform root 每个 job 签一张 30 分钟证书，过期即失效，
# 无需吊销，也不存在静态凭据。私钥在 Bao 内生成且不可导出（type = internal）。
resource "vault_mount" "pki_incus" {
  path                  = "pki-incus"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10y — 须覆盖根证书自身寿命
}

resource "vault_pki_secret_backend_root_cert" "incus" {
  backend     = vault_mount.pki_incus.path
  type        = "internal"
  common_name = "ddupan homelab Incus client CA"
  ttl         = "315360000"
  key_type    = "ec"
  key_bits    = 256

  lifecycle {
    # 换根 = 所有 Incus 主机的 server.ca 都要重新下发；只能有意为之。
    prevent_destroy = true
  }
}

resource "vault_pki_secret_backend_role" "incus_ci" {
  backend = vault_mount.pki_incus.path
  name    = "ci-terraform"

  # 只签客户端证书；CN 仅作审计时辨认，Incus 不据此授权。
  allowed_domains    = ["ci-terraform"]
  allow_bare_domains = true
  allow_subdomains   = false
  allow_ip_sans      = false
  server_flag        = false
  client_flag        = true
  key_type           = "ec"
  key_bits           = 256
  ttl                = 1800
  max_ttl            = 3600
  # 短期证书不入存储，也就无从吊销——过期本身就是撤销机制。
  no_store = true
}
