variable "region" {
  type    = string
  default = "ap-osaka-1"
}
# 本地用 API key；CI 由 tf.py 设为 SecurityToken（SPIRE 换来的 UPST）。
variable "oci_auth" {
  type    = string
  default = "ApiKey"
}
variable "oci_config_profile" {
  type    = string
  default = "DEFAULT"
}
variable "compartment_ocid" {
  type    = string
  default = "ocid1.tenancy.oc1..aaaaaaaalncmdinfnljot5oh7rqleavphhsa6jpyurfu4luztcct3tp5gsfa"
}
# 固定现有启动镜像；查询最新 Ubuntu 镜像不应触发现有实例重建。
variable "image_ocid" {
  type    = string
  default = "ocid1.image.oc1.ap-osaka-1.aaaaaaaayniglvbm5xyligxib2nk3jz3zendq6ywckp4gppteii4tg7wzhua"
}
variable "instance_metadata" {
  description = "从受限 state 副本提取的原实例 metadata；仅存于忽略的本地 tfvars。"
  type        = map(string)
  sensitive   = true
}

# rclone obscure 后的值，和 Bao kv/k8s/tfstate-backup 的 crypt_password 相同。
# tf.py 从 kv/infra/terraform/oci 注入；这个 root 现在要经 tf.py 运行才有这个值。
variable "tfstate_backup_crypt_password" {
  type      = string
  sensitive = true
}

# rclone obscure 后的值，和 Bao kv/k8s/gitea-backup-drive 的 crypt_password 相同。
# tf.py 从 kv/infra/terraform/oci 注入。
variable "gitea_backup_drive_crypt_password" {
  type      = string
  sensitive = true
}

# CI 从 Bao kv/infra/terraform/oci 注入（tf.py 的 TF_VAR_ 约定）。只需 Zone · DNS : Edit（ddupan.top），
# 不复用 cloudflared root 那把带 Tunnel/SSL/Workers 权限的 token。
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type        = string
  description = "ddupan.top 的 Cloudflare zone ID"
}
