# 账单只读身份：platform/observability/metrics/exporters/cloud-cost.yaml 的 CronJob 用它查 Usage API，
# 金额写进 VictoriaMetrics，告警走 Alertmanager，所以这里没有 OCI Budget。
#
# 费用：服务用户、组、策略和 Usage API 都不收费。
#
# 映射规则在 spire-federation.tf 的 trust 里。一个 SPIFFE ID 只能映射一个用户，这个 Pod 有自己的
# SPIFFE ID，所以能用真正只读的用户，而不是 terraform-ci。
locals {
  cost_collector_subject = "spiffe://ddupan.top/ns/monitoring/sa/cloud-cost"
}

# 不和 terraform-ci 共用 spire_exchange：应用各用各的 client，轮换或泄露时互不影响。
# 费用：身份域应用不收费。
resource "oci_identity_domains_app" "cost_exchange" {
  idcs_endpoint   = local.identity_domain_url
  schemas         = ["urn:ietf:params:scim:schemas:oracle:idcs:App"]
  display_name    = "cost-collector-token-exchange"
  description     = "Client the cloud-cost collector uses to exchange its JWT-SVID for a UPST"
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

resource "oci_identity_domains_user" "cost_reader" {
  idcs_endpoint = local.identity_domain_url
  schemas = [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "urn:ietf:params:scim:schemas:oracle:idcs:extension:user:User",
  ]
  user_name   = "cost-reader"
  description = "Impersonated by the cloud-cost collector through the SPIRE token exchange"

  urnietfparamsscimschemasoracleidcsextensionuser_user {
    service_user = true
  }

  # OCI 会往 schemas 里追加扩展，不忽略的话每次 plan 都有 diff。
  lifecycle {
    ignore_changes = [schemas]
  }
}

resource "oci_identity_group" "cost_reader" {
  compartment_id = var.compartment_ocid
  name           = "cost-reader"
  description    = "Read tenancy cost and usage data"
}

resource "oci_identity_user_group_membership" "cost_reader" {
  user_id  = oci_identity_domains_user.cost_reader.ocid
  group_id = oci_identity_group.cost_reader.id
}

resource "oci_identity_policy" "cost_reader" {
  compartment_id = var.compartment_ocid
  name           = "cost-reader"
  description    = "Cost collector reads usage reports only"
  statements = [
    "Allow group ${oci_identity_group.cost_reader.name} to read usage-report in tenancy",
  ]
}

# apply 后写进 Bao kv/k8s/cloud-cost（oci_client_id、oci_client_secret），见 ../README.md。
output "cost_exchange_client_id" {
  value = oci_identity_domains_app.cost_exchange.name
}

output "cost_exchange_client_secret" {
  value     = oci_identity_domains_app.cost_exchange.client_secret
  sensitive = true
}
