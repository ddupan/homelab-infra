# 远端 state，与其他 root 相同（原因见 apps/seaweedfs/terraform/backend.tf）：
# 本地 state 只存在于 laptop 这一单点，且无法加锁。Nexus 已由 POC 转为正式使用，不再允许本地 state。
# 凭据不写入此文件：运行前从 Bao kv/k8s/seaweedfs-s3 取 `terraform` 受限身份导出为 AWS_* 环境变量。
terraform {
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "nexus/terraform.tfstate"
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
