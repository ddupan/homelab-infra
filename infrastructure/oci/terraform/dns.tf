# 指向 OCI 实例公网 IP 的记录跟实例放在同一个 root（CLAUDE.md：记录跟着创建它所指对象的代码走）。
# 公网 IP 是 ephemeral 的，只有删除重建实例才会变；放在这里，重建时记录随 apply 一起更新，
# 不用再手工改 Cloudflare，也不需要跨 root 引用。

# 登录用，不经代理。
resource "cloudflare_dns_record" "oci_arm" {
  zone_id = var.cloudflare_zone_id
  name    = "oci-arm.ddupan.top"
  type    = "A"
  content = oci_core_instance.vm.public_ip
  proxied = false
  ttl     = 300
}

resource "cloudflare_dns_record" "oci_amd" {
  zone_id = var.cloudflare_zone_id
  name    = "oci-amd.ddupan.top"
  type    = "A"
  content = oci_core_instance.amd.public_ip
  proxied = false
  ttl     = 300
}

# Gitea 源站。经 Cloudflare 代理（Full strict + Origin CA），443 只放 CF 网段，见 gitea-ingress.tf。
# Origin CA 证书和 git.ddupan.top 的 config rule 仍在 infrastructure/cloudflared/terraform。
resource "cloudflare_dns_record" "gitea" {
  zone_id = var.cloudflare_zone_id
  name    = "git.ddupan.top"
  type    = "A"
  content = oci_core_instance.vm.public_ip
  proxied = true
  ttl     = 1
}
