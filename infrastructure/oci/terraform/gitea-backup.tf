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
    # 所有备份统一留 7 天。付费账号的 Standard 免费额度是 10 GB，一份 dump 约 0.9 GB
    # （大头是 actions_artifacts），7 天约 6 GB。dump 明显变大时降低 Gitea 的 ARTIFACT_RETENTION_DAYS。
    time_amount = 7
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
