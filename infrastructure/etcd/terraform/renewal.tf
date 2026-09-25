# 独立挂载：不接管全局认证，不保存长期 token，也不授权 KV 消费者秘密读取。
data "vault_generic_secret" "etcd_ca" {
  path = "${var.pki_mount}/cert/ca"
}

resource "vault_auth_backend" "etcd_renewal" {
  type = "cert"
  path = "homelab-etcd-renewal"
}

resource "vault_policy" "etcd_renewal" {
  name = "homelab-etcd-renewal"
  policy = join("\n", concat([
    for kind in ["server", "peer", "admin", "gateway"] :
    "path \"${var.pki_mount}/sign/homelab-etcd-${kind}\" { capabilities = [\"update\"] }"
  ], ["path \"auth/token/revoke-self\" { capabilities = [\"update\"] }"]))
}

resource "vault_cert_auth_backend_role" "etcd_renewal" {
  backend                 = vault_auth_backend.etcd_renewal.path
  name                    = "etcd-laptop"
  certificate             = data.vault_generic_secret.etcd_ca.data["certificate"]
  allowed_dns_sans        = ["etcd-laptop"]
  token_policies          = [vault_policy.etcd_renewal.name]
  token_no_default_policy = true
  token_ttl               = 600
  token_max_ttl           = 900
}
