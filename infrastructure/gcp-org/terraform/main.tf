# 组织级授权，只在本地运行，不进 CI：CI 的 terraform-ci 只是项目 owner，读不了组织的 IAM，
# 也不该能读。为什么需要它见 ../../gcp-ci/terraform/main.tf 的 google_org_policy_policy。
terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
  }
}

# 用户凭据调 Org Policy API 必须指定配额项目。
provider "google" {
  billing_project       = "ddupan-ci"
  user_project_override = true
}

# Organization Admin 不包含修改组织策略的权限，这个角色也只能在组织级授予。
resource "google_organization_iam_member" "policy_admin" {
  org_id = "74885522592"
  role   = "roles/orgpolicy.policyAdmin"
  member = "user:panxiao81.pp@gmail.com"
}
