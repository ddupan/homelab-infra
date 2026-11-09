terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}

# 本地用 Application Default Credentials。CI 由 .gitea/scripts/tf.py 提供 SPIRE 联邦凭据。
provider "google" {
  project = var.project_id
  region  = var.region
  # 用户凭据调 Org Policy API 必须指定配额项目。
  billing_project       = var.project_id
  user_project_override = true
}

provider "vault" {
  address = "https://bao.lab.ddupan.top:8200"
  # The wrapper's short-lived token; it revokes it afterwards, so no child token is needed.
  skip_child_token = true
}
