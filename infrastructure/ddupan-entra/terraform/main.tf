# ddupan.top 租户（Microsoft 365 订阅）里用 Terraform 做的变更都放这个 root，按用途分文件（gitea.tf …）。
data "azuread_client_config" "current" {}
