# Per-application consumers of Ayatori Prod credentials, one bao role + policy each, bound to the
# app's OWN ServiceAccount (`<namespace>-database`), so the shared external-secrets identity never
# gains read on tenant credentials. Same shape as iam_login_database (auth.tf), which predates this
# map and is left as is to avoid moving its state.
#
# The path is fixed by the Database UID: read it from the Tenant's status.credentialRef on
# ayatori-prod (`k0s kubectl get postgresqltenant -A`). Tenants: ../../../clusters/ayatori-prod/;
# consumers: <app>/database.yaml.
locals {
  ayatori_prod_database_consumers = {
    artifact-keeper = "d4a890b8-7a34-4108-aa24-e94eb4127939"
    backstage       = "16837b48-acc9-42f0-8fb9-acfff9582943"
    e5renew         = "f05cbf75-e4d1-47c7-a4af-9fa2e7f7e2f5"
    research-auto   = "1fde1e74-c2fa-4580-a7f0-93513bbee433"
    spire-server    = "3c561678-1239-4d57-9ace-54c309926fc8"
  }
}

resource "vault_policy" "ayatori_prod_database" {
  for_each = local.ayatori_prod_database_consumers

  name   = "${each.key}-database"
  policy = <<-EOT
    # ${each.key} 在 homelab k3s 的 ESO 身份：只读 Ayatori Prod 交付给它的那一份应用凭据。
    path "kv/data/ayatori/prod/applications/${each.value}" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "ayatori_prod_database" {
  for_each = local.ayatori_prod_database_consumers

  backend   = "kubernetes"
  role_name = "${each.key}-database"

  bound_service_account_names      = ["${each.key}-database"]
  bound_service_account_namespaces = [each.key]

  token_policies = [vault_policy.ayatori_prod_database[each.key].name]
  token_ttl      = 3600
}
