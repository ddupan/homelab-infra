# Gitea（oci-arm）直接用公网 IP，git.ddupan.top 在 Cloudflare 开代理。443 只放 Cloudflare：
# 否则爬虫可以直连源站 IP，绕过 cloudflared/terraform 里针对 git.ddupan.top 的 WAF 挑战
# （2026-11-01 爬虫打满过 Gitea）。源站证书是 Cloudflare Origin CA，本来也只有 CF 信任。
# 专用 NSG 挂在 A1 的 VNIC 上，不放进共用安全列表——同子网的 AMD 不需要 443。
locals {
  # https://www.cloudflare.com/ips-v4，2026-11-04 取。CF 很少改，改了就同步这里。
  cloudflare_ipv4 = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]
}

resource "oci_core_network_security_group" "gitea" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "homelab-vm-gitea"
}

resource "oci_core_network_security_group_security_rule" "gitea_https" {
  for_each                  = toset(local.cloudflare_ipv4)
  network_security_group_id = oci_core_network_security_group.gitea.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.key
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "Cloudflare proxy to Gitea origin"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}
