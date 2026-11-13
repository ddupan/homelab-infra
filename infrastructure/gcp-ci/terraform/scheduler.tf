# gitea-dynamic-runner 的 cloud-scheduler（platform/dynamic-runner）在 homelab 里运行，用 SPIRE
# JWT-SVID 经联邦以这个服务账号调用 GKE API，为 runs-on: [cloud] 的 job 创建一次性 Pod。
locals {
  scheduler_subject = "spiffe://ddupan.top/ns/dynamic-runner/sa/dynamic-runner-controller"
  # 和 controller 的 CLOUD_NAMESPACE、CLOUD_SERVICE_ACCOUNT 默认值一致。
  executor_namespace = "gitea-actions"
}

resource "google_service_account" "scheduler" {
  account_id   = "dynamic-runner-controller"
  display_name = "gitea-dynamic-runner cloud-scheduler"

  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "scheduler" {
  service_account_id = google_service_account.scheduler.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.spire.name}/subject/${local.scheduler_subject}"
}

# 项目只跑 CI，不再细分 Kubernetes RBAC（gitea-dynamic-runner docs/cloud-executor.md）。
resource "google_project_iam_member" "scheduler" {
  project = google_project.ci.project_id
  role    = "roles/container.developer"
  member  = google_service_account.scheduler.member
}

resource "kubernetes_namespace_v1" "executor" {
  metadata {
    name = local.executor_namespace
  }
}

# Pod 不挂 token（automountServiceAccountToken: false），这里只是给 Pod 一个没有任何权限的身份。
resource "kubernetes_service_account_v1" "executor" {
  metadata {
    name      = "gitea-task-executor"
    namespace = kubernetes_namespace_v1.executor.metadata[0].name
  }
  automount_service_account_token = false
}

# homelab 的 platform/dynamic-runner/runner-config.yaml 的云端版本。没有 job_started hook：
# 它等待 SPIRE socket，这里没有，会超时失败。
resource "kubernetes_config_map_v1" "runner_config" {
  metadata {
    name      = "gitea-runner-config"
    namespace = kubernetes_namespace_v1.executor.metadata[0].name
  }
  data = {
    "config.yaml" = yamlencode({
      runner = {
        capacity         = 1
        timeout          = "3h"
        shutdown_timeout = "1m"
      }
      # cache-server.tf：runner 把 job 的 token 注册过去并转发 job 的缓存请求。
      cache = {
        external_server      = "http://${google_compute_address.cache_server.address}:${local.cache_server_port}/"
        external_secret_file = "/run/gitea-runner-cache/external_secret"
      }
      host = {
        workdir_parent = "/workspace"
      }
      container = {
        require_docker = false
        valid_volumes  = []
      }
    })
  }
}

# 名字沿用 GCS 时代（controller 的 CLOUD_RUNNER_CACHE_SECRET 引用它），现在只放 cache-server 的共享密钥。
resource "kubernetes_secret_v1" "runner_cache" {
  metadata {
    name      = "gitea-runner-cache-gcs"
    namespace = kubernetes_namespace_v1.executor.metadata[0].name
  }
  data = {
    external_secret = random_password.cache_server_secret.result
  }
}
