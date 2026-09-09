# Feed these into smtp-relay/secret.yaml (CLIENT_ID / CLIENT_SECRET / TENANT_ID).
#   terraform output -raw client_id
#   terraform output -raw tenant_id
#   terraform output -raw client_secret

output "client_id" {
  value       = azuread_application.smtp_relay.client_id
  description = "CLIENT_ID for the relay secret."
}

output "tenant_id" {
  value       = data.azuread_client_config.current.tenant_id
  description = "TENANT_ID for the relay secret."
}

