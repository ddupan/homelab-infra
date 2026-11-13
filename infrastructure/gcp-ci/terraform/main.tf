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

  # Pod labels (ci.ddupan.top/repo, size, ...) reach the Detailed billing
  # export, so CI cost splits by repository (../../gcp-billing).
  cost_management_config {
    enabled = true
  }

  # Autopilot turns on Managed Prometheus with cAdvisor, kubelet, kube-state and
  # Dataplane V2 metrics. They are billed per sample and were nearly all of the
  # trial credit spent (2026-11); the cloud pool is watched from homelab through
  # cloud-scheduler's metrics instead. System metrics are free and stay.
  # Managed Prometheus itself cannot be turned off on Autopilot (1.25+, the API
  # rejects it); with no components and no PodMonitoring it ingests nothing.
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
    # Autopilot keeps these on whatever is requested; nothing scrapes them, so
    # they ingest no samples. false only left a permanent plan diff.
    advanced_datapath_observability_config {
      enable_metrics = true
      enable_relay   = false
    }
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

# ponytail: cache 已不用 HMAC key，这条例外可以删了，但删除要组织级 orgpolicy.policies.delete，CI 的
# terraform-ci 没有（#768 的 apply 因此中断）。留着它，等本地用组织管理员身份删除（../../gcp-org/terraform）。
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
