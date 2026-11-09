# 机器用 SPIRE JWT-SVID 换 OCI UPST（约 1 小时），不再需要长期 API key。换 token 的代码在
# .gitea/scripts/tf.py。client secret 单独拿不到 OCI 权限，还必须持有匹配的 JWT-SVID。
# apply 后把 client id/secret 写进 Bao kv/infra/oci-token-exchange（client_id、client_secret）。

locals {
  identity_domain_url = "https://idcs-15519d43fa4e4b2588e6c0ffa5be9423.identity.oraclecloud.com:443"
  spire_issuer        = "https://spire-oidc.ddupan.top"
  # 与 apps/iam-login/application.yaml 的 admin-ids 相同：CI 的 plan/apply，加本机开发身份。
  terraform_ci_subjects = toset([
    "spiffe://ddupan.top/ci/panxiao81/homelab-infra/terraform-plan",
    "spiffe://ddupan.top/ci/panxiao81/homelab-infra/terraform-apply",
    "spiffe://ddupan.top/dev/panxiao81",
  ])
}

resource "oci_identity_domains_app" "spire_exchange" {
  idcs_endpoint   = local.identity_domain_url
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  display_name    = "spire-token-exchange"
  description     = "Client allowed to exchange SPIRE JWT-SVIDs for UPSTs"
  client_type     = "confidential"
  is_oauth_client = true
  allowed_grants  = ["client_credentials"]
  active          = true

  based_on_template {
    value = "CustomWebAppTemplateId"
  }

  # OCI 会往 schemas 里追加扩展，不忽略的话每次 plan 都有 diff。
  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_domains_user" "terraform_ci" {
  idcs_endpoint = local.identity_domain_url
  schemas = [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:user:User",
  ]
  user_name   = "terraform-ci"
  description = "Impersonated by Terraform CD through the SPIRE token exchange"

  urnietfparamsscimschemasoracleidcsextensionuser_user {
    service_user = true
  }

  # OCI 会往 schemas 里追加扩展，不忽略的话每次 plan 都有 diff。
  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_domains_identity_propagation_trust" "spire" {
  idcs_endpoint       = local.identity_domain_url
  schemas             = ["urn:ietf:params:scim:schemas:oracle:idcs:IdentityPropagationTrust"]
  name                = "spire"
  description         = "SPIRE JWT-SVIDs (trust domain ddupan.top)"
  type                = "JWT"
  issuer              = local.spire_issuer
  public_key_endpoint = "${local.spire_issuer}/keys"
  subject_type        = "User"
  active              = true
  oauth_clients       = [oci_identity_domains_app.spire_exchange.name, oci_identity_domains_app.cost_exchange.name]
  allow_impersonation = true
  # 默认读取不返回 impersonation_service_users，不加的话每次 plan 都显示要新增。
  attribute_sets = ["all"]
  # OCI 默认不校验 aud，发给其他服务的 JWT-SVID 也能换 token。绑定后不匹配时返回 500，不是 4xx，
  # 所以换 token 失败不要重试。
  client_claim_name   = "aud"
  client_claim_values = ["oci"]

  dynamic "impersonation_service_users" {
    for_each = local.terraform_ci_subjects
    content {
      rule  = "sub eq ${impersonation_service_users.value}"
      value = oci_identity_domains_user.terraform_ci.id
    }
  }

  impersonation_service_users {
    rule  = "sub eq ${local.cost_collector_subject}"
    value = oci_identity_domains_user.cost_reader.id
  }
}

resource "oci_identity_group" "terraform_ci" {
  compartment_id = var.compartment_ocid
  name           = "terraform-ci"
  description    = "Terraform CD for this root"
}

resource "oci_identity_user_group_membership" "terraform_ci" {
  user_id  = oci_identity_domains_user.terraform_ci.ocid
  group_id = oci_identity_group.terraform_ci.id
}

# 这个 root 管 IAM、网络、实例和身份联邦本身，收窄权限只是假象（同 Bao 的 ci-terraform）。
resource "oci_identity_policy" "terraform_ci" {
  compartment_id = var.compartment_ocid
  name           = "terraform-ci"
  description    = "Terraform CD manages this tenancy"
  statements = [
    "Allow group ${oci_identity_group.terraform_ci.name} to manage all-resources in tenancy",
  ]
}

output "spire_exchange_client_id" {
  value = oci_identity_domains_app.spire_exchange.name
}

output "spire_exchange_client_secret" {
  value     = oci_identity_domains_app.spire_exchange.client_secret
  sensitive = true
}
