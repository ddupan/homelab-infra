# 与既有服务复用受限 tfstate 身份，使用独立对象与原生锁；不复用 Bao 的 state。
terraform {
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "incus/terraform.tfstate"
    endpoints                   = { s3 = "https://s3.lab.ddupan.top" }
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
