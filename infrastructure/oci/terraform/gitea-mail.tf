# Gitea（oci-arm）的发信：OCI Email Delivery（Always Free 每月 3000 封）。不走 lab 的 smtp-relay，
# 因为 Gitea 已经搬出 lab，通知邮件不该依赖 lab。lab 的 smtp-relay 见 smtp-relay-mail.tf。
#
# 只做 DKIM，不改 ddupan.top 的 SPF：SPF 是 Cloudflare 面板里手工维护的记录（icloud + outlook），再
# include 一个 Oracle 会逼近 10 次查询上限；DMARC 只需 SPF 或 DKIM 之一对齐，DKIM（d=ddupan.top）就够。
# DKIM 的 CNAME 发布在 infrastructure/cloudflared/terraform（gitea-origin.tf 旁边）。

resource "oci_email_email_domain" "ddupan" {
  compartment_id = var.compartment_ocid
  name           = "ddupan.top"
}

resource "oci_email_dkim" "gitea" {
  email_domain_id = oci_email_email_domain.ddupan.id
  # selector 带区域和年月：同一域名在多个区域发信时 selector 必须不同；轮换时新建一个再删旧的。
  name = "oci-kix-202611"
}

resource "oci_email_sender" "gitea" {
  compartment_id = var.compartment_ocid
  email_address  = "noreply@ddupan.top"
}

# SMTP 凭据挂在专用用户上：它只能发信，泄露时删掉这个用户即可，不牵连控制台账号。
resource "oci_identity_user" "gitea_smtp" {
  compartment_id = var.compartment_ocid
  name           = "gitea-smtp"
  description    = "SMTP only: Gitea on oci-arm sends mail via Email Delivery"
  email          = "noreply@ddupan.top"
}

resource "oci_identity_group" "gitea_smtp" {
  compartment_id = var.compartment_ocid
  name           = "gitea-smtp"
  description    = "May send mail through Email Delivery"
}

resource "oci_identity_user_group_membership" "gitea_smtp" {
  user_id  = oci_identity_user.gitea_smtp.id
  group_id = oci_identity_group.gitea_smtp.id
}

resource "oci_identity_policy" "gitea_smtp" {
  compartment_id = var.compartment_ocid
  name           = "gitea-smtp"
  description    = "gitea-smtp may send via approved senders"
  statements = [
    "Allow group ${oci_identity_group.gitea_smtp.name} to use approved-senders in tenancy",
  ]
}

# 密码只在创建时返回，所以会进 state（本 root 的 state 在 OCI Object Storage，不在 lab）。
# apply 后写进 OCI Vault ansible-gitea 的 vault_gitea_smtp_user / vault_gitea_smtp_password 键（ansible/README.md）。
resource "oci_identity_smtp_credential" "gitea" {
  user_id     = oci_identity_user.gitea_smtp.id
  description = "gitea on oci-arm"
}

output "gitea_mail_dkim_cname" {
  description = "发布到 Cloudflare：name CNAME value（infrastructure/cloudflared/terraform）。"
  value = {
    name  = oci_email_dkim.gitea.dns_subdomain_name
    value = oci_email_dkim.gitea.cname_record_value
  }
}

output "gitea_smtp_username" {
  value = oci_identity_smtp_credential.gitea.username
}

output "gitea_smtp_password" {
  value     = oci_identity_smtp_credential.gitea.password
  sensitive = true
}
