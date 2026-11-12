# Gitea（oci-arm）每日 `gitea dump` 的去处。实例以 instance principal 上传，磁盘上没有凭据；
# 策略只给 OBJECT_CREATE / OBJECT_INSPECT：被攻破的实例能写新备份，但删不掉也覆盖不了旧的。
# 过期由 lifecycle 规则在服务端执行，同样不经过实例。

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

resource "oci_objectstorage_bucket" "gitea_backup" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "gitea-backup"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

resource "oci_objectstorage_object_lifecycle_policy" "gitea_backup" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.gitea_backup.name

  rules {
    name       = "expire-gitea-dumps"
    action     = "DELETE"
    is_enabled = true
    target     = "objects"
    # 只留 2 天：付费账号的 Standard 免费额度是 10 GB，一份 dump 约 0.8 GB（大头是
    # actions_artifacts），7 天要 6.4 GB，挤占其他备份。更长的历史由 lab 的
    # gitea-backup-drive CronJob 拷到 Google Drive（apps/gitea-backup-drive/）。
    # 这 2 天也是那个 Job 的追赶窗口：lab 停摆超过 2 天，Drive 上会缺对应日期。
    time_amount = 2
    time_unit   = "DAYS"
  }

  # lifecycle 规则以 Object Storage 服务身份删除对象，缺这条授权时 apply 直接报 400。
  depends_on = [oci_identity_policy.gitea_backup]
}

resource "oci_identity_dynamic_group" "gitea_backup" {
  compartment_id = var.compartment_ocid
  name           = "homelab-vm-gitea-backup"
  description    = "oci-arm (homelab-vm) uploading Gitea dumps"
  matching_rule  = "instance.id = '${oci_core_instance.vm.id}'"
}

resource "oci_identity_policy" "gitea_backup" {
  compartment_id = var.compartment_ocid
  name           = "gitea-backup"
  description    = "oci-arm writes Gitea dumps; Object Storage expires them"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.gitea_backup.name} to manage objects in tenancy where all {target.bucket.name = '${oci_objectstorage_bucket.gitea_backup.name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT'}}",
    "Allow service objectstorage-${var.region} to manage object-family in tenancy where target.bucket.name = '${oci_objectstorage_bucket.gitea_backup.name}'",
  ]
}

output "gitea_backup_bucket" {
  value = {
    namespace = data.oci_objectstorage_namespace.ns.namespace
    name      = oci_objectstorage_bucket.gitea_backup.name
  }
}

# lab 的 gitea-backup-drive CronJob 从这里读 dump、加密后拷到 Google Drive。
# 只读：Drive 一侧的保留和清理不经过 OCI，这个身份不能写也不能删。
# 笔记本集群用不了 instance principal，所以和 tfstate-backup 一样发 Customer Secret Key。
resource "oci_identity_user" "gitea_backup_drive" {
  compartment_id = var.compartment_ocid
  name           = "gitea-backup-drive"
  description    = "Reads Gitea dumps from the laptop cluster to copy them to Google Drive"
  email          = "gitea-backup-drive@ddupan.top"
}

resource "oci_identity_group" "gitea_backup_drive" {
  compartment_id = var.compartment_ocid
  name           = "gitea-backup-drive"
  description    = "May list and read the gitea-backup bucket"
}

resource "oci_identity_user_group_membership" "gitea_backup_drive" {
  user_id  = oci_identity_user.gitea_backup_drive.id
  group_id = oci_identity_group.gitea_backup_drive.id
}

resource "oci_identity_policy" "gitea_backup_drive" {
  compartment_id = var.compartment_ocid
  name           = "gitea-backup-drive"
  description    = "gitea-backup-drive reads Gitea dumps"
  statements = [
    "Allow group ${oci_identity_group.gitea_backup_drive.name} to read objects in tenancy where target.bucket.name = '${oci_objectstorage_bucket.gitea_backup.name}'",
  ]
}

# secret 只在创建时返回，会进 state。apply 后写进 Bao kv/k8s/gitea-backup-drive，
# 步骤见 apps/gitea-backup-drive/README.md。
resource "oci_identity_customer_secret_key" "gitea_backup_drive" {
  user_id      = oci_identity_user.gitea_backup_drive.id
  display_name = "laptop-cluster"
}

output "gitea_backup_drive_access_key" {
  value = oci_identity_customer_secret_key.gitea_backup_drive.id
}

output "gitea_backup_drive_secret_key" {
  value     = oci_identity_customer_secret_key.gitea_backup_drive.key
  sensitive = true
}

# Drive 上的 dump 用 rclone crypt 加密（里面有 app.ini 的 SECRET_KEY 和整个数据库）。
# 解密只需要这个密码；Drive 本身用 Google 账号就能登录下载，所以只有它需要放到 lab 之外。
# vault 与密钥复用 tfstate-backup.tf 的 recovery。
resource "oci_vault_secret" "gitea_backup_drive_recovery" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.recovery.id
  key_id         = oci_kms_key.recovery.id
  secret_name    = "gitea-backup-drive-recovery"
  description    = "rclone crypt password for the Gitea dumps on Google Drive (see apps/gitea-backup-drive/README.md)"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(jsonencode({ crypt_password = var.gitea_backup_drive_crypt_password }))
  }
}
