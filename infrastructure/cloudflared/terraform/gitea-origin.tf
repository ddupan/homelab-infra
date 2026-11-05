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

# 代理 A 记录直指 A1 公网 IP。地址是 ephemeral 公网 IP：重启、停机再启动都保留，只有删除重建实例才会变
# （infrastructure/oci/terraform 的 instance_public_ip）。不用 terraform_remote_state 跨 root 引用，见 CLAUDE.md。
# 爬虫防护在 Gitea 自己（REQUIRE_SIGNIN_VIEW = expensive），这里不再有 WAF 规则：lab 内客户端也经 CF，
# 边缘挑战会拦下 Backstage 这类非浏览器客户端。
resource "cloudflare_dns_record" "gitea" {
  zone_id = var.zone_id
  name    = "git.ddupan.top"
  type    = "A"
  content = "129.225.138.179"
  proxied = true
  ttl     = 1
}
