# Workload authentication via SPIFFE JWT-SVIDs. The discovery document and
# JWKS contain public verification material, so this backend carries no secret.
#
# Keys come straight from the JWKS rather than discovery (platform/spire/README.md,
# "Issuer migration"): a fixed key URL keeps working through any future issuer change,
# where discovery would fail the moment the document's issuer and the URL differ.
resource "vault_jwt_auth_backend" "spire" {
  path         = "jwt-spire"
  description  = "SPIFFE JWT-SVID workload authentication"
  jwks_url     = "https://spire-oidc.lab.ddupan.top/keys"
  bound_issuer = "https://spire-oidc.ddupan.top"
}

# First end-to-end identity. Keep the subject exact: this role is deliberately
# not a wildcard escape hatch for every workload in the trust domain.
resource "vault_jwt_auth_backend_role" "spire_poc" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "spire-poc"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/ns/spire-poc/sa/spire-jwt-poc"
  }

  token_policies          = [vault_policy.spire_poc.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Local development on the laptop. Keep the subject exact: possession of any
# other identity in the trust domain must not grant interactive host access.
resource "vault_jwt_auth_backend_role" "local_development" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "local-development"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/dev/panxiao81"
  }

  # local-development grants normal KV v2 read/write under kv/k8s and kv/infra,
  # plus short-lived SSH certificate signing.
  # certificate signing; spire-poc only permits lookup and revocation of the
  # caller's own short-lived Bao token.
  token_policies = [
    vault_policy.local_development.name,
    vault_policy.spire_poc.name,
  ]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Every repository publishes TechDocs from a job named `techdocs` through
# panxiao81/ci-actions/publish-techdocs. The job key comes from Gitea's trusted
# task payload (gitea-dynamic-runner taskidentity), not from workflow input.
# ponytail: one shared publisher identity, so any of these repositories can
# overwrite another's docs; split into per-repository roles and S3 identities
# once repositories outside this single owner publish docs.
resource "vault_jwt_auth_backend_role" "ci_techdocs_publisher" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-techdocs-publisher"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "glob"
  bound_claims = {
    # Comma-separated values are alternatives: Gitea executors (repos still on Gitea) and GitHub
    # techdocs.yml jobs via spire-identity-exchange (platform/spire/github-ci.yaml).
    sub = "spiffe://ddupan.top/ci/panxiao81/*/techdocs,spiffe://ddupan.top/ci/github/ddupan/*/techdocs"
  }

  token_policies          = [vault_policy.ci_techdocs_publisher.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Provider releases (terraform-provider-*/.github/workflows/release.yml, job key `release`) upload builds
# to the static Terraform registry. Signing stays with the maintainer's YubiKey, not CI.
resource "vault_jwt_auth_backend_role" "ci_terraform_registry_publisher" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-terraform-registry-publisher"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "glob"
  bound_claims = {
    # GitHub release.yml jobs via spire-identity-exchange (platform/spire/github-ci.yaml).
    sub = "spiffe://ddupan.top/ci/github/ddupan/terraform-provider-*/release"
  }

  token_policies          = [vault_policy.ci_terraform_registry_publisher.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# homelab-cookbooks publish.yml uploads new cookbook versions to the static supermarket bucket
# (apps/seaweedfs/terraform/chef-supermarket.tf). GitHub job via spire-identity-exchange; its SPIRE
# entry (platform/spire/github-ci.yaml) matches only publish.yml on main for push events.
resource "vault_jwt_auth_backend_role" "ci_chef_supermarket_publisher" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-chef-supermarket-publisher"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "string"
  bound_claims = {
    sub = "spiffe://ddupan.top/ci/github/ddupan/homelab-cookbooks/publish"
  }

  token_policies          = [vault_policy.ci_chef_supermarket_publisher.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Terraform CI (.github/workflows/terraform.yml)：PR 上的 terraform-plan 与 main 上的
# terraform-apply。job key 来自 Gitea 可信 task payload，不是 workflow 输入。
# 用 admin policy 是如实反映：openbao root 本身管理 policy 与 auth，任何更窄的
# policy 都能被这条流水线 apply 成更宽，收窄只是假象。代价是任何能在本仓库开 PR 的人
# 都能以 admin 运行 plan——单作者前提成立时可接受，有第二个提交者时必须重新评估。
# 必须先在本地 apply 一次：流水线无法用尚不存在的 role 创建它自己。
resource "vault_jwt_auth_backend_role" "ci_terraform" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-terraform"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "glob"
  bound_claims = {
    # Gitea executor and, during the move, the same job on GitHub (spire-identity-exchange).
    sub = "spiffe://ddupan.top/ci/panxiao81/homelab-infra/terraform-*,spiffe://ddupan.top/ci/github/ddupan/homelab-infra/terraform-*"
  }

  token_policies          = [vault_policy.admin.name]
  token_no_default_policy = true
  # vault provider 的子 token 受父 token 剩余 TTL 限制；openbao root 的 plan/apply
  # 远超 local-development 的 5 分钟。
  token_ttl     = 1800
  token_max_ttl = 3600
}

# 依赖升级评审（ci-actions/upgrade-review）：panxiao81 下任何仓库里名为 upgrade-review 的 job。
# PR 由 renovate-bot 开，但能在这些仓库开 PR 的人都能改 workflow 以此身份运行，拿到的是一把可吊销的
# 模型 key 和 OpenSandbox API key——后者能创建不带 egress 策略的 sandbox（可达内网），所以这些仓库
# 不能接受外部 PR。
resource "vault_jwt_auth_backend_role" "ci_upgrade_review" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-upgrade-review"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "glob"
  bound_claims = {
    sub = "spiffe://ddupan.top/ci/panxiao81/*/upgrade-review"
  }

  token_policies          = [vault_policy.ci_upgrade_review.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Cinc converge CI (infrastructure/chef/): job keys converge-* (why-run on PRs, apply
# on main). Only an SSH signer for root on the converged nodes; the policy archive is
# built in the job and needs no secret. Like ci-terraform, anyone who can open a PR
# here can run why-run as root on those nodes — revisit with a second committer.
resource "vault_jwt_auth_backend_role" "ci_converge" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-converge"
  role_type = "jwt"

  user_claim        = "sub"
  bound_audiences   = ["openbao"]
  bound_claims_type = "glob"
  bound_claims = {
    # Gitea executor and, during the move, the same job on GitHub (spire-identity-exchange).
    sub = "spiffe://ddupan.top/ci/panxiao81/homelab-infra/converge-*,spiffe://ddupan.top/ci/github/ddupan/homelab-infra/converge-*"
  }

  token_policies          = [vault_policy.ci_converge.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Ansible host deploy on merge (.github/workflows/host-deploy.yml). Exact subject: the job only runs on
# push to main, but like ci-converge a PR could rename a job to host-deploy and run it — revisit with a
# second committer. Only an SSH signer; the playbooks it runs need no secrets (that was the point of
# moving oci/samba-ad off ansible-vault, #838 #841).
resource "vault_jwt_auth_backend_role" "ci_host_deploy" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "ci-host-deploy"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    # Gitea executor and, during the move, the same job on GitHub (spire-identity-exchange).
    sub = "spiffe://ddupan.top/ci/panxiao81/homelab-infra/host-deploy,spiffe://ddupan.top/ci/github/ddupan/homelab-infra/host-deploy"
  }

  token_policies          = [vault_policy.ci_host_deploy.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 900
}

# Renovate on oci-arm (platform/spire/oci-arm.yaml: a dedicated uid on that instance). Exact subject:
# this identity reads the renovate-bot token, which can push to every repository Renovate manages.
resource "vault_jwt_auth_backend_role" "renovate" {
  backend   = vault_jwt_auth_backend.spire.path
  role_name = "renovate"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["openbao"]
  bound_claims = {
    sub = "spiffe://ddupan.top/node/oci-arm/renovate"
  }

  token_policies          = [vault_policy.renovate.name]
  token_no_default_policy = true
  token_ttl               = 300
  token_max_ttl           = 300
}
