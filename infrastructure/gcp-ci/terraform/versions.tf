terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
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

# ponytail: no vault resources remain; drop this provider once the apply that deleted kv k8s/gitea-runner-cache-gcs has run.
provider "vault" {
  address = "https://bao.lab.ddupan.top:8200"
  # The wrapper's short-lived token; it revokes it afterwards, so no child token is needed.
  skip_child_token = true
}

# 同一个 root 刚建的集群：terraform-ci 是项目 owner，直接用它的 access token。
data "google_client_config" "this" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.ci.endpoint}"
  token                  = data.google_client_config.this.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.ci.master_auth[0].cluster_ca_certificate)
}
