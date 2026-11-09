# pg-prod 每日 pg_dumpall 的异地副本，只用于紧急恢复；平时的 PITR 走本地 pgBackRest。
# 上传机在 lab 里用不了 instance principal，只能发 Customer Secret Key（S3 兼容接口）。策略只有
# OBJECT_CREATE：上传机被攻破也读不到、覆盖不了、删不掉已有副本。恢复时用管理员身份下载，
# 再用 YubiKey 解密（上传前已 GPG 加密）。

resource "oci_objectstorage_bucket" "pg_dump" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "pg-dump"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

resource "oci_objectstorage_object_lifecycle_policy" "pg_dump" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.pg_dump.name

  rules {
    name       = "expire-pg-dumps"
    action     = "DELETE"
    is_enabled = true
    target     = "objects"
    # 所有备份统一留 7 天，够发现问题并回滚。
    time_amount = 7
    time_unit   = "DAYS"
  }

  # lifecycle 规则以 Object Storage 服务身份删除对象，缺这条授权时 apply 直接报 400。
  depends_on = [oci_identity_policy.pg_dump]
}

resource "oci_identity_user" "pg_dump" {
  compartment_id = var.compartment_ocid
  name           = "pg-dump"
  description    = "Uploads encrypted pg-prod dumps from the pgBackRest repository host"
  email          = "pg-dump@ddupan.top"
}

resource "oci_identity_group" "pg_dump" {
  compartment_id = var.compartment_ocid
  name           = "pg-dump"
  description    = "May create new objects in the pg-dump bucket"
}

resource "oci_identity_user_group_membership" "pg_dump" {
  user_id  = oci_identity_user.pg_dump.id
  group_id = oci_identity_group.pg_dump.id
}

resource "oci_identity_policy" "pg_dump" {
  compartment_id = var.compartment_ocid
  name           = "pg-dump"
  description    = "The repository host writes new dumps; Object Storage expires them"
  statements = [
    "Allow group ${oci_identity_group.pg_dump.name} to manage objects in tenancy where all {target.bucket.name = '${oci_objectstorage_bucket.pg_dump.name}', request.permission = 'OBJECT_CREATE'}",
    "Allow service objectstorage-${var.region} to manage object-family in tenancy where target.bucket.name = '${oci_objectstorage_bucket.pg_dump.name}'",
  ]
}

# secret 只在创建时返回，所以会进 state（本 root 的 state 不在 lab）。apply 后写进 Bao 的
# kv/infra/postgresql/offsite，由 infrastructure/shared-postgresql 的 backup.yml 读取。
resource "oci_identity_customer_secret_key" "pg_dump" {
  user_id      = oci_identity_user.pg_dump.id
  display_name = "pg-pve2"
}

output "pg_dump_access_key" {
  value = oci_identity_customer_secret_key.pg_dump.id
}

output "pg_dump_secret_key" {
  value     = oci_identity_customer_secret_key.pg_dump.key
  sensitive = true
}
