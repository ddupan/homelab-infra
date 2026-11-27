# Not secrets: a federated identity's client ID and audience only work together with an OIDC
# token whose claims match. They go into homelab-infra's repository variables (see README).
output "github_variables" {
  value = {
    TS_OIDC_CLIENT_ID     = tailscale_federated_identity.ci_runner.id
    TS_OIDC_AUDIENCE      = tailscale_federated_identity.ci_runner.audience
    TS_TF_PLAN_CLIENT_ID  = tailscale_federated_identity.terraform_plan.id
    TS_TF_PLAN_AUDIENCE   = tailscale_federated_identity.terraform_plan.audience
    TS_TF_APPLY_CLIENT_ID = tailscale_federated_identity.terraform_apply.id
    TS_TF_APPLY_AUDIENCE  = tailscale_federated_identity.terraform_apply.audience
  }
}
