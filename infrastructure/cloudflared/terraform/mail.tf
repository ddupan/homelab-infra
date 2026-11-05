# ddupan.top 的 SPF。原先在 Cloudflare 面板手工维护，2026-11-05 接管进来（import 块保留无害：已在 state 时为 no-op）。
#
# 只有 M365 以 ddupan.top 作为信封发件人发信。iCloud 的自定义域名转发已经停用，去掉了 include:icloud.com。
# OCI Email Delivery（Gitea 通知，infrastructure/oci/terraform/gitea-mail.tf）刻意不加：它靠 DKIM 对齐通过
# DMARC，信封发件人是 Oracle 自己的域名，这里加 include 也不会对齐。
import {
  to = cloudflare_dns_record.spf
  id = "${var.zone_id}/11163e2eb397b4c9dbb4ef4018e73553"
}

resource "cloudflare_dns_record" "spf" {
  zone_id = var.zone_id
  name    = "ddupan.top"
  type    = "TXT"
  # 引号是 Cloudflare 存储的原样（面板创建时带上的），去掉会造成永久 diff。
  content = "\"v=spf1 include:spf.protection.outlook.com ~all\""
  ttl     = 3600
}

# OCI Email Delivery 的 DKIM（Gitea 通知，infrastructure/oci/terraform/gitea-mail.tf）。值来自那边的
# `terraform output gitea_mail_dkim_cname`；不用 terraform_remote_state 跨 root 引用（CLAUDE.md）。
# selector 轮换时：那边新建 oci_email_dkim，这里加新记录，激活后再删旧的。
resource "cloudflare_dns_record" "dkim_oci_kix_202611" {
  zone_id = var.zone_id
  name    = "oci-kix-202611._domainkey.ddupan.top"
  type    = "CNAME"
  content = "oci-kix-202611.ddupan.top.dkim.kix1.oracleemaildelivery.com"
  proxied = false
  ttl     = 3600
}
