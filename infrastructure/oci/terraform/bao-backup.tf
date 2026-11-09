# bao1 的 Raft 快照异地副本。bao1 在 lab 里用不了 instance principal，只能给专用用户发
# Customer Secret Key（S3 兼容接口）。策略只有 OBJECT_CREATE：bao1 被攻破也读不到、覆盖不了、
# 删不掉已有副本，所以这把 key 不用像 tfstate-backup 那样在 OCI Vault 留恢复用的一份，
# 恢复时用管理员身份下载，再用 YubiKey 解密（快照上传前已 GPG 加密）。

resource "oci_objectstorage_bucket" "bao_snapshot" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "bao-snapshot"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
}

resource "oci_objectstorage_object_lifecycle_policy" "bao_snapshot" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = oci_objectstorage_bucket.bao_snapshot.name

  rules {
    name       = "expire-bao-snapshots"
    action     = "DELETE"
    is_enabled = true
    target     = "objects"
    # 一份约 0.5 MB，30 天不到 20 MB。比 bao1 本地的 14 份留得久，发现得晚也还能回滚。
    time_amount = 30
    time_unit   = "DAYS"
  }

  # lifecycle 规则以 Object Storage 服务身份删除对象，缺这条授权时 apply 直接报 400。
  depends_on = [oci_identity_policy.bao_snapshot]
}

resource "oci_identity_user" "bao_snapshot" {
  compartment_id = var.compartment_ocid
  name           = "bao-snapshot"
  description    = "Uploads encrypted OpenBao Raft snapshots from bao1"
  email          = "bao-snapshot@ddupan.top"
}

resource "oci_identity_group" "bao_snapshot" {
  compartment_id = var.compartment_ocid
  name           = "bao-snapshot"
  description    = "May create new objects in the bao-snapshot bucket"
}

resource "oci_identity_user_group_membership" "bao_snapshot" {
  user_id  = oci_identity_user.bao_snapshot.id
  group_id = oci_identity_group.bao_snapshot.id
}

resource "oci_identity_policy" "bao_snapshot" {
  compartment_id = var.compartment_ocid
  name           = "bao-snapshot"
  description    = "bao1 writes new snapshots; Object Storage expires them"
  statements = [
    "Allow group ${oci_identity_group.bao_snapshot.name} to manage objects in tenancy where all {target.bucket.name = '${oci_objectstorage_bucket.bao_snapshot.name}', request.permission = 'OBJECT_CREATE'}",
    "Allow service objectstorage-${var.region} to manage object-family in tenancy where target.bucket.name = '${oci_objectstorage_bucket.bao_snapshot.name}'",
  ]
}

# secret 只在创建时返回，所以会进 state（本 root 的 state 不在 lab）。apply 后写进
# infrastructure/openbao/ansible 的 ansible-vault：openbao 不能从 Bao 读自己的密钥。
resource "oci_identity_customer_secret_key" "bao_snapshot" {
  user_id      = oci_identity_user.bao_snapshot.id
  display_name = "bao1"
}

output "bao_snapshot_access_key" {
  value = oci_identity_customer_secret_key.bao_snapshot.id
}

output "bao_snapshot_secret_key" {
  value     = oci_identity_customer_secret_key.bao_snapshot.key
  sensitive = true
}
