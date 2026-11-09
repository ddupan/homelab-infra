# 项目也由这个 root 管。deletion_policy 默认 PREVENT，从配置里删掉不会连带删项目。
resource "google_project" "ci" {
  project_id      = var.project_id
  name            = var.project_id
  org_id          = var.org_id
  billing_account = var.billing_account
}

resource "google_project_service" "this" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "orgpolicy.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  project = google_project.ci.project_id
  service = each.value
  # Other resources in the project may still depend on these APIs.
  disable_on_destroy = false
}

# Executors for jobs that need neither Docker nor the LAN. Autopilot allows no
# privileged Pods and no SPIFFE CSI driver, so these run without a SPIRE identity.
resource "google_container_cluster" "ci" {
  name             = "ci"
  location         = var.region
  enable_autopilot = true
  # 集群里没有需要保留的东西，换区域时要能直接重建。
  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.this]
}

# 镜像只发布到 ghcr.io，节点经这个同区域的远程仓库拉取。Cloud Run 也能用，且不需要直接访问 ghcr。
resource "google_artifact_registry_repository" "ghcr" {
  repository_id = "ghcr"
  location      = var.region
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    common_repository {
      uri = "https://ghcr.io"
    }
  }

  # 免费额度只有 0.5 GB。这里只是 ghcr 的缓存，删掉后下次拉取会重新回源。
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "expire-cached-images"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "7d"
    }
  }

  depends_on = [google_project_service.this]
}

# 集群没有指定节点 SA，用的是默认 Compute SA，它在这个项目上默认没有任何角色。
locals {
  node_service_account = "serviceAccount:${google_project.ci.number}-compute@developer.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "ghcr_node_reader" {
  repository = google_artifact_registry_repository.ghcr.name
  location   = google_artifact_registry_repository.ghcr.location
  role       = "roles/artifactregistry.reader"
  member     = local.node_service_account
}

# 节点上报日志和指标需要这个角色。
resource "google_project_iam_member" "node_default" {
  project = google_project.ci.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = local.node_service_account
}

# Actions cache for the cloud pool, the counterpart of the SeaweedFS ci-cache
# bucket (apps/seaweedfs/terraform/ci-cache.tf). Everything in it is disposable.
resource "google_storage_bucket" "ci_cache" {
  name                        = "${var.project_id}-ci-cache"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The runner does not evict S3 caches itself.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  depends_on = [google_project_service.this]
}

resource "google_service_account" "ci_cache" {
  account_id   = "gitea-runner-cache"
  display_name = "Gitea runner Actions cache"

  depends_on = [google_project_service.this]
}

resource "google_storage_bucket_iam_member" "ci_cache" {
  bucket = google_storage_bucket.ci_cache.name
  role   = "roles/storage.objectUser"
  member = google_service_account.ci_cache.member
}

# 组织策略禁止创建服务账号密钥，HMAC key 也算在内。只在这个项目放开：cache.s3 只能走 S3 协议，
# 这把 key 也只能读写这一个桶。修改需要组织级的 policyAdmin（../../gcp-org/terraform）。
resource "google_org_policy_policy" "allow_cache_hmac_key" {
  name   = "projects/${google_project.ci.project_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "projects/${google_project.ci.project_id}"

  spec {
    rules {
      enforce = "FALSE"
    }
  }

  depends_on = [google_project_service.this]
}

# The runner's `cache.s3` speaks the S3 API, which GCS serves with HMAC keys.
resource "google_storage_hmac_key" "ci_cache" {
  service_account_email = google_service_account.ci_cache.email

  depends_on = [google_org_policy_policy.allow_cache_hmac_key]
}

# Same fields as k8s/gitea-runner-cache-s3. Host-mode jobs can read them, so
# every repository in the cloud pool shares one cache trust domain.
resource "vault_kv_secret_v2" "ci_cache" {
  mount = "kv"
  name  = "k8s/gitea-runner-cache-gcs"
  data_json = jsonencode({
    access_key = google_storage_hmac_key.ci_cache.access_id
    secret_key = google_storage_hmac_key.ci_cache.secret
  })
}
