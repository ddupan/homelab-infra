# lab 的 smtp-relay（apps/smtp-relay，k3s）经 OCI Email Delivery 发信，替代 M365：ddupan.top 的
# M365 开发者沙盒约 2027-01-23 被微软清退。发件人、DKIM 复用 gitea-mail.tf 的 noreply@ddupan.top
# 和 oci-kix-202611；免费额度（每月 3000 封）与 Gitea 共用，PVE 告警量远低于此。
#
# 单独一个用户而不是复用 gitea-smtp 的凭据：lab 里的凭据泄露时删掉这个用户即可，不影响 Gitea。
# 组复用 gitea-smtp：它的策略只是「可经已批准的发件人发信」，不含 Gitea 特有的权限。

resource "oci_identity_user" "smtp_relay" {
  compartment_id = var.compartment_ocid
  name           = "smtp-relay"
  description    = "SMTP only: the lab smtp-relay (k3s) sends mail via Email Delivery"
  email          = "smtp-relay@ddupan.top"
}

resource "oci_identity_user_group_membership" "smtp_relay" {
  user_id  = oci_identity_user.smtp_relay.id
  group_id = oci_identity_group.gitea_smtp.id
}

# 密码只在创建时返回，所以会进 state（本 root 的 state 不在 lab）。apply 后合并写进 Bao 的
# kv/k8s/smtp-relay（RELAYHOST_USERNAME / RELAYHOST_PASSWORD），ESO 同步给 relay。
resource "oci_identity_smtp_credential" "smtp_relay" {
  user_id     = oci_identity_user.smtp_relay.id
  description = "lab smtp-relay (k3s)"
}

output "smtp_relay_smtp_username" {
  value = oci_identity_smtp_credential.smtp_relay.username
}

output "smtp_relay_smtp_password" {
  value     = oci_identity_smtp_credential.smtp_relay.password
  sensitive = true
}
