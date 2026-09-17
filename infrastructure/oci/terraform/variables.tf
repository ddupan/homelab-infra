variable "region" {
  type    = string
  default = "ap-osaka-1"
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
