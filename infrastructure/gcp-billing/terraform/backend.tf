# State 放在局域网的 SeaweedFS：本机是单点，本地 state 也无法加锁。
# 凭据不写在这里，由 .github/scripts/tf.py 从 Bao 读取后只传给子进程。
terraform {
  backend "s3" {
    bucket = "tfstate"
    key    = "gcp-billing/terraform.tfstate"

    endpoints = {
      s3 = "https://s3.lab.ddupan.top"
    }

    # SeaweedFS 不是 AWS，没有 region、IAM 和账号 ID，这些校验必须跳过。
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
