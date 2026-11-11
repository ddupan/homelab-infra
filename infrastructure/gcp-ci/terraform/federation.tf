# CI 用 SPIRE JWT-SVID 登录 GCP，没有服务账号密钥（组织策略也禁止创建）。
# allowed_audiences 绑定 aud，发给其他服务的 JWT-SVID 不能拿来换 token。
locals {
  terraform_ci_subjects = toset([
    "spiffe://ddupan.top/ci/panxiao81/homelab-infra/terraform-plan",
    "spiffe://ddupan.top/ci/panxiao81/homelab-infra/terraform-apply",
    "spiffe://ddupan.top/dev/panxiao81",
  ])
}

resource "google_iam_workload_identity_pool" "spire" {
  project                   = google_project.ci.project_id
  workload_identity_pool_id = "spire"
  display_name              = "SPIRE"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "spire" {
  project                            = google_project.ci.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.spire.workload_identity_pool_id
  workload_identity_pool_provider_id = "spire"
  attribute_mapping                  = { "google.subject" = "assertion.sub" }
  attribute_condition                = "assertion.sub in ${jsonencode(concat(tolist(local.terraform_ci_subjects), [local.scheduler_subject]))}"

  oidc {
    issuer_uri        = "https://spire-oidc.ddupan.top"
    allowed_audiences = ["gcp"]
  }
}

resource "google_service_account" "terraform_ci" {
  project      = google_project.ci.project_id
  account_id   = "terraform-ci"
  display_name = "Terraform CD"

  depends_on = [google_project_service.this]
}

resource "google_service_account_iam_member" "terraform_ci" {
  for_each = local.terraform_ci_subjects

  service_account_id = google_service_account.terraform_ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.spire.name}/subject/${each.value}"
}

# 这个 root 管项目本身，收窄权限没有实际意义（同 OCI 的 terraform-ci）。
resource "google_project_iam_member" "terraform_ci" {
  project = google_project.ci.project_id
  role    = "roles/owner"
  member  = google_service_account.terraform_ci.member
}

# google_project 每次 plan 都要读计费账号。
resource "google_billing_account_iam_member" "terraform_ci" {
  billing_account_id = var.billing_account
  role               = "roles/billing.viewer"
  member             = google_service_account.terraform_ci.member
}
