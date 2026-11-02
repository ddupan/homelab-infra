terraform {
  required_version = ">= 1.11.0"
  required_providers {
    # aws_iam_user 需要 SeaweedFS >= 4.48：更早版本的 GetUser 不返回 Arn，provider 会超时。
    aws   = { source = "hashicorp/aws", version = "~> 6.0" }
    vault = { source = "hashicorp/vault", version = "~> 5.0" }
  }
}

provider "vault" {
  address = "https://bao.lab.ddupan.top:8200"
  # 使用包装器取得的短期 token；它负责执行后撤销，不要求额外创建子 token。
  skip_child_token = true
}

# s3-admin 是静态身份（-s3.config），只存在 kv/k8s/seaweedfs-s3 一处；此处读取而非
# 复制到 kv/infra/terraform/seaweedfs，避免两份凭据漂移。IAM API 需要 Admin action。
data "vault_kv_secret_v2" "s3_config" {
  mount = "kv"
  name  = "k8s/seaweedfs-s3"
}

locals {
  s3_config = jsondecode(data.vault_kv_secret_v2.s3_config.data["seaweedfs_s3_config"])
  s3_admin  = one([for i in local.s3_config.identities : one(i.credentials) if i.name == "s3-admin"])
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = local.s3_admin.accessKey
  secret_key                  = local.s3_admin.secretKey
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  endpoints {
    s3  = "https://s3.lab.ddupan.top"
    iam = "https://s3.lab.ddupan.top"
  }
}
