terraform {
  required_version = ">= 1.15.8, < 2.0.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "9.11.0"
    }
  }
  # 已停用旧执行流程，当前根模块直接管理既有对象；不迁移本地恢复副本。
  backend "oci" {
    bucket              = "oci-k8s-free-tier-tfstate"
    namespace           = "axckv9ylwqxr"
    key                 = "terraform.tfstate"
    region              = "ap-osaka-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}
