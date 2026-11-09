data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # 由 ../../gcp-ci/terraform/federation.tf 创建。这里按名字引用，仓库不用 terraform_remote_state。
  spire_pool = "projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/spire"
}

# 费用：启用 API 不收费。
resource "google_project_service" "bigquery" {
  project = var.project_id
  service = "bigquery.googleapis.com"
  # 项目里的其他资源可能也依赖这个 API。
  disable_on_destroy = false
}

# 导出本身只能在控制台开启（见 ../README.md），这里只建目标数据集。
#
# 没有 google_billing_budget：金额由 cloud-cost CronJob 写进 VictoriaMetrics，阈值和告警都在
# platform/observability/metrics/rules/cloud-cost.yaml，走现有的 Alertmanager。
#
# 费用：导出写入免费；存储每月前 10 GiB 免费，超出约 $0.01/GiB 起；查询每月前 1 TiB 免费，超出约
# $6.25/TiB（2026-11 官方定价页）。单项目的 Standard 导出是 MB 级，CronJob 每 3 小时查一次，每次按
# 最低 10 MB 计，一个月约 2.4 GB，预期一直是 ¥0。
# 没开 Detailed 导出：只有一个 CI 项目，SKU 级够用，Detailed 的表更大、查询也更贵。
resource "google_bigquery_dataset" "billing" {
  project     = var.project_id
  dataset_id  = "billing_export"
  description = "Cloud Billing standard usage cost export"

  # 必须是多区域：首次导出才会回填到上月初，单区域数据集没有历史。location 建好后不能改，
  # 改用新数据集也不会带上旧数据。
  location = "US"

  # 账单历史无法重新导出，不随 destroy 删除。
  delete_contents_on_destroy = false

  depends_on = [google_project_service.bigquery]
}

# 只读身份。费用：服务账号、IAM 和 Workload Identity Federation 都不收费。
resource "google_service_account" "reader" {
  project      = var.project_id
  account_id   = "finops-reader"
  display_name = "Read-only billing analysis"
}

# 现有 spire provider 的 attribute_condition 归 gcp-ci 管，而且只放行 Terraform 身份。
# 采集器用单独的 provider，这个 root 不用改别人的联邦配置。
resource "google_iam_workload_identity_pool_provider" "billing" {
  project                            = var.project_id
  workload_identity_pool_id          = "spire"
  workload_identity_pool_provider_id = "spire-billing"
  attribute_mapping                  = { "google.subject" = "assertion.sub" }
  attribute_condition                = "assertion.sub == \"${var.collector_subject}\""

  oidc {
    issuer_uri        = "https://spire-oidc.ddupan.top"
    allowed_audiences = ["gcp"]
  }
}

resource "google_service_account_iam_member" "reader" {
  for_each = toset([var.developer_subject, var.collector_subject])

  service_account_id = google_service_account.reader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${local.spire_pool}/subject/${each.value}"
}

# 用 *_iam_member 而不是 dataset 的 access 块：导出服务账号的写权限是控制台开启导出时加的，
# 权威式配置会把它删掉，导出随之静默中断。
resource "google_bigquery_dataset_iam_member" "reader" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.billing.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = google_service_account.reader.member
}

# 运行查询任务需要项目级权限，数据访问仍然受上面的数据集授权限制。
resource "google_project_iam_member" "reader_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_service_account.reader.member
}

output "reader_email" {
  value = google_service_account.reader.email
}

output "billing_dataset" {
  value = "${var.project_id}.${google_bigquery_dataset.billing.dataset_id}"
}
