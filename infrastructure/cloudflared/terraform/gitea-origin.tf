# Gitea（oci-arm）源站证书。git.ddupan.top 走 Cloudflare 代理直连 A1 公网 IP（不经 tunnel），
# CF 以 Full (strict) 校验源站，Origin CA 证书只被 CF 信任——lab 内客户端因此也必须经 CF 访问。
#
# 私钥不在这里生成：tls_private_key 会把私钥写进本 root 的 state（在 lab 的 S3 上）。
# 私钥只存在 infrastructure/oci/ansible/host_vars/oci_arm/vault.yml（vault_gitea_tls_key），
# 这里只提交公开的 CSR。轮换：重新生成私钥与 CSR，替换文件后 apply。
resource "cloudflare_origin_ca_certificate" "gitea" {
  csr                = file("${path.module}/gitea-origin.csr")
  hostnames          = ["git.ddupan.top"]
  request_type       = "origin-ecc"
  requested_validity = 5475
}

# 公开证书，apply 后写进 oci ansible 的 host_vars/oci_arm/gitea.yml（gitea_tls_cert）。
output "gitea_origin_certificate" {
  value = cloudflare_origin_ca_certificate.gitea.certificate
}
