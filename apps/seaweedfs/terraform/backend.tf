# 远端 state，与其他 root 相同（原因见 apps/smtp-relay/terraform/backend.tf）。
# backend 凭据是 tfstate 受限身份（AWS_* 环境变量，由 .gitea/scripts/tf.py 注入）；
# provider 用的是 s3-admin，见 main.tf。
terraform {
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "seaweedfs/terraform.tfstate"
    endpoints                   = { s3 = "https://s3.ad.ddupan.top" }
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
