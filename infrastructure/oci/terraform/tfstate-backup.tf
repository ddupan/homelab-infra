# lab 的 tfstate 异地副本写到本 root 的 state 桶下 seaweedfs-tfstate/ 前缀（apps/seaweedfs/tfstate-backup.yaml）。
# 笔记本集群用不了 instance principal，只能给专用用户发 Customer Secret Key（S3 兼容接口）。
# 只留最新版，所以需要 OBJECT_OVERWRITE，没有删除权限；对象都是密文，泄露最多破坏这份备份。

locals {
  tfstate_bucket = "oci-k8s-free-tier-tfstate"
}

resource "oci_identity_user" "tfstate_backup" {
  compartment_id = var.compartment_ocid
  name           = "tfstate-backup"
  description    = "Uploads encrypted lab tfstate copies from the laptop cluster"
  email          = "tfstate-backup@ddupan.top"
}

resource "oci_identity_group" "tfstate_backup" {
  compartment_id = var.compartment_ocid
  name           = "tfstate-backup"
  description    = "May write the seaweedfs-tfstate/ prefix of the tfstate bucket"
}

resource "oci_identity_user_group_membership" "tfstate_backup" {
  user_id  = oci_identity_user.tfstate_backup.id
  group_id = oci_identity_group.tfstate_backup.id
}

resource "oci_identity_policy" "tfstate_backup" {
  compartment_id = var.compartment_ocid
  name           = "tfstate-backup"
  description    = "tfstate-backup writes only under seaweedfs-tfstate/"
  statements = [
    "Allow group ${oci_identity_group.tfstate_backup.name} to manage objects in tenancy where all {target.bucket.name = '${local.tfstate_bucket}', target.object.name = 'seaweedfs-tfstate/*', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_OVERWRITE', request.permission = 'OBJECT_READ'}}",
    # 列举请求没有对象名，上一条的前缀条件匹配不了，只能按桶放开；暴露的只有对象名。
    "Allow group ${oci_identity_group.tfstate_backup.name} to inspect objects in tenancy where target.bucket.name = '${local.tfstate_bucket}'",
  ]
}

# secret 只在创建时返回，所以会进 state（本 root 的 state 不在 lab）。
# apply 后写进 Bao kv/k8s/tfstate-backup，并在 lab 外留一份，步骤见 apps/seaweedfs/README.md。
resource "oci_identity_customer_secret_key" "tfstate_backup" {
  user_id      = oci_identity_user.tfstate_backup.id
  display_name = "laptop-cluster"
}

output "tfstate_backup_access_key" {
  value = oci_identity_customer_secret_key.tfstate_backup.id
}

output "tfstate_backup_secret_key" {
  value     = oci_identity_customer_secret_key.tfstate_backup.key
  sensitive = true
}

# 恢复 tfstate 备份要用的三个值放一份在 OCI Vault，lab 全挂时登录 OCI 控制台就能取到。
# 和备份同在一个账号：账号没了备份本来也没了，放这里不损失可用性；代价是 OCI 管理员
# 能同时拿到密文和密码。tfstate-backup 用户没有这里的权限。
# DEFAULT vault 和 SOFTWARE 密钥都在 Always Free 内（150 个 secret，软件密钥不限量）。
resource "oci_kms_vault" "recovery" {
  compartment_id = var.compartment_ocid
  display_name   = "recovery"
  vault_type     = "DEFAULT"
}

resource "oci_kms_key" "recovery" {
  compartment_id      = var.compartment_ocid
  display_name        = "recovery"
  management_endpoint = oci_kms_vault.recovery.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}

resource "oci_vault_secret" "tfstate_backup_recovery" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.recovery.id
  key_id         = oci_kms_key.recovery.id
  secret_name    = "tfstate-backup-recovery"
  description    = "Values needed to restore the encrypted tfstate backup (see apps/seaweedfs/README.md)"

  secret_content {
    content_type = "BASE64"
    content = base64encode(jsonencode({
      oci_access_key = oci_identity_customer_secret_key.tfstate_backup.id
      oci_secret_key = oci_identity_customer_secret_key.tfstate_backup.key
      crypt_password = var.tfstate_backup_crypt_password
    }))
  }
}
