# dc1（唯一的 Samba AD DC）每日 `samba-tool domain backup offline` 的异地副本。
# 域 SID、账号、密码哈希和 krbtgt 密钥都没法从 IaC 重建，lab 全挂时只能靠这里。
# dc1 是 laptop 上的 libvirt VM，用不了 instance principal，所以发 Customer Secret Key；
# 策略只给 OBJECT_CREATE / OBJECT_INSPECT：dc1 被攻破也删不掉、覆盖不了旧备份。
# 归档在 dc1 上先用 rclone crypt 加密，对象本身是密文。
# 角色在 infrastructure/samba-ad/ansible/roles/samba_ad_backup。

resource "oci_objectstorage_bucket" "dc1_backup" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "dc1-backup"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

resource "oci_objectstorage_object_lifecycle_policy" "dc1_backup" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.dc1_backup.name

  rules {
    name       = "expire-dc1-backups"
    action     = "DELETE"
    is_enabled = true
    target     = "objects"
    # 一份几 MB，7 天对 10 GB 免费额度可以忽略。
    time_amount = 7
    time_unit   = "DAYS"
  }

  # lifecycle 规则以 Object Storage 服务身份删除对象，缺这条授权时 apply 直接报 400。
  depends_on = [oci_identity_policy.dc1_backup]
}

resource "oci_identity_user" "dc1_backup" {
  compartment_id = var.compartment_ocid
  name           = "dc1-backup"
  description    = "Uploads encrypted Samba AD backups from dc1"
  email          = "dc1-backup@ddupan.top"
}

resource "oci_identity_group" "dc1_backup" {
  compartment_id = var.compartment_ocid
  name           = "dc1-backup"
  description    = "May create objects in the dc1-backup bucket"
}

resource "oci_identity_user_group_membership" "dc1_backup" {
  user_id  = oci_identity_user.dc1_backup.id
  group_id = oci_identity_group.dc1_backup.id
}

resource "oci_identity_policy" "dc1_backup" {
  compartment_id = var.compartment_ocid
  name           = "dc1-backup"
  description    = "dc1 writes Samba AD backups; Object Storage expires them"
  statements = [
    "Allow group ${oci_identity_group.dc1_backup.name} to manage objects in tenancy where all {target.bucket.name = '${oci_objectstorage_bucket.dc1_backup.name}', any {request.permission = 'OBJECT_CREATE', request.permission = 'OBJECT_INSPECT'}}",
    "Allow service objectstorage-${var.region} to manage object-family in tenancy where target.bucket.name = '${oci_objectstorage_bucket.dc1_backup.name}'",
  ]
}

# secret 只在创建时返回，会进 state。apply 后写进 Bao kv/infra/dc1-backup，
# 步骤见 infrastructure/samba-ad/README.md 的 Backups 一节。
resource "oci_identity_customer_secret_key" "dc1_backup" {
  user_id      = oci_identity_user.dc1_backup.id
  display_name = "dc1"
}

output "dc1_backup_access_key" {
  value = oci_identity_customer_secret_key.dc1_backup.id
}

output "dc1_backup_secret_key" {
  value     = oci_identity_customer_secret_key.dc1_backup.key
  sensitive = true
}

# 恢复只需要 crypt 密码：密文从 OCI 控制台就能下载。Bao 也在 lab 里，所以放一份在
# OCI Vault（vault 与密钥复用 tfstate-backup.tf 的 recovery）。
resource "oci_vault_secret" "dc1_backup_recovery" {
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.recovery.id
  key_id         = oci_kms_key.recovery.id
  secret_name    = "dc1-backup-recovery"
  description    = "rclone crypt password for the dc1 Samba AD backups (see infrastructure/samba-ad/README.md)"

  secret_content {
    content_type = "BASE64"
    content      = base64encode(jsonencode({ crypt_password = var.dc1_backup_crypt_password }))
  }
}
