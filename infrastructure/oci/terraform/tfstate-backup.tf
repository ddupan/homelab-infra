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
