# The whole tailnet policy file. Terraform owns it from here: edits in the admin console are
# reverted by the next apply on main.
resource "tailscale_acl" "policy" {
  acl = file("${path.module}/policy.hujson")
}

# Split DNS. Before this root existed these were set by hand in the admin console.
# lab.ddupan.top: Blocky on the laptop; ad.ddupan.top: the DC; oraclevcn.com: OCI's resolver,
# reachable from tailnet clients only via homelab-vm's own route.
locals {
  split_dns = {
    "ad.ddupan.top"  = ["192.168.10.5"]
    "lab.ddupan.top" = ["192.168.10.127"]
    "oraclevcn.com"  = ["169.254.169.254"]
  }
}

resource "tailscale_dns_split_nameservers" "this" {
  for_each    = local.split_dns
  domain      = each.key
  nameservers = each.value
}

# GitHub Actions identities. GitHub's default sub claim is repo:<owner>/<repo>:<context>; the
# workflow file is pinned through job_workflow_ref, because sub alone says nothing about which
# workflow runs. PR jobs get read-only access, main gets write: a PR's plan must never be able
# to change the tailnet.
locals {
  github_issuer = "https://token.actions.githubusercontent.com"
  terraform_workflow = {
    job_workflow_ref = "ddupan/homelab-infra/.github/workflows/terraform.yml@*"
  }
}

# Joins the job's runner to the tailnet as an ephemeral tag:ci node (tailscale/github-action);
# policy.hujson decides what tag:ci may reach.
resource "tailscale_federated_identity" "ci_runner" {
  description        = "homelab-infra terraform runner"
  issuer             = local.github_issuer
  subject            = "repo:ddupan/homelab-infra:*"
  custom_claim_rules = local.terraform_workflow
  scopes             = ["auth_keys"]
  tags               = ["tag:ci"]
  depends_on         = [tailscale_acl.policy] # tag:ci must be owned before it can be granted
}

# This root's own API access. Managing these two here means a bad change can lock CI out of the
# Tailscale API; recover with a local apply and TAILSCALE_API_KEY.
resource "tailscale_federated_identity" "terraform_plan" {
  description        = "homelab-infra terraform plan"
  issuer             = local.github_issuer
  subject            = "repo:ddupan/homelab-infra:pull_request"
  custom_claim_rules = local.terraform_workflow
  scopes             = ["all:read"]
}

resource "tailscale_federated_identity" "terraform_apply" {
  description        = "homelab-infra terraform apply"
  issuer             = local.github_issuer
  subject            = "repo:ddupan/homelab-infra:ref:refs/heads/main"
  custom_claim_rules = local.terraform_workflow
  # policy_file requires devices:posture_attributes and devices:core:read alongside it.
  scopes = ["policy_file", "devices:posture_attributes", "devices:core:read", "dns", "federated_keys"]
}
