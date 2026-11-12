# laptop 上 k3s 的数据存储（SQLite state.db）+ server token 的异地副本。
# token 是 bootstrap 数据（集群 CA 等）的加密密钥，两者缺一不可（docs.k3s.io/datastore/backup-restore）。
# 应用本身能靠 Flux + ESO 重建，这份备份保住的是集群身份：CA、kubeconfig、SA 签名密钥，
# 以及 ESO / SPIRE 对 k8s 的信任。laptop 用不了 instance principal，发 Customer Secret Key；
# 策略只有 OBJECT_CREATE，laptop 被攻破也读不到、覆盖不了、删不掉已有副本。
# 上传前已 GPG 加密给 YubiKey，恢复时用管理员身份下载。play 在 infrastructure/host-backup/。

resource "oci_objectstorage_bucket" "k3s_backup" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "k3s-backup"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

resource "oci_objectstorage_object_lifecycle_policy" "k3s_backup" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.k3s_backup.name

  rules {
    name       = "expire-k3s-backups"
    action     = "DELETE"
    is_enabled = true
    target     = "objects"
    # 所有备份统一留 7 天。压缩后一份约 30 MB，7 份约 0.2 GB。
    time_amount = 7
    time_unit   = "DAYS"
  }

  # lifecycle 规则以 Object Storage 服务身份删除对象，缺这条授权时 apply 直接报 400。
  depends_on = [oci_identity_policy.k3s_backup]
}

resource "oci_identity_user" "k3s_backup" {
  compartment_id = var.compartment_ocid
  name           = "k3s-backup"
  description    = "Uploads encrypted k3s datastore backups from the laptop"
  email          = "k3s-backup@ddupan.top"
}

resource "oci_identity_group" "k3s_backup" {
  compartment_id = var.compartment_ocid
  name           = "k3s-backup"
  description    = "May create new objects in the k3s-backup bucket"
}

resource "oci_identity_user_group_membership" "k3s_backup" {
  user_id  = oci_identity_user.k3s_backup.id
  group_id = oci_identity_group.k3s_backup.id
}

resource "oci_identity_policy" "k3s_backup" {
  compartment_id = var.compartment_ocid
  name           = "k3s-backup"
  description    = "The laptop writes new k3s backups; Object Storage expires them"
  statements = [
    "Allow group ${oci_identity_group.k3s_backup.name} to manage objects in tenancy where all {target.bucket.name = '${oci_objectstorage_bucket.k3s_backup.name}', request.permission = 'OBJECT_CREATE'}",
    "Allow service objectstorage-${var.region} to manage object-family in tenancy where target.bucket.name = '${oci_objectstorage_bucket.k3s_backup.name}'",
  ]
}

# secret 只在创建时返回，所以会进 state（本 root 的 state 不在 lab）。apply 后写进 Bao 的
# kv/infra/k3s-backup，由 infrastructure/host-backup/laptop-k3s-backup.yml 读取。
resource "oci_identity_customer_secret_key" "k3s_backup" {
  user_id      = oci_identity_user.k3s_backup.id
  display_name = "laptop"
}

output "k3s_backup_access_key" {
  value = oci_identity_customer_secret_key.k3s_backup.id
}

output "k3s_backup_secret_key" {
  value     = oci_identity_customer_secret_key.k3s_backup.key
  sensitive = true
}
