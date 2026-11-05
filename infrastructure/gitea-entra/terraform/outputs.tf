output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "client_id" {
  value = azuread_application.gitea.client_id
}

output "client_secret" {
  value     = azuread_application_password.gitea.value
  sensitive = true
}

output "client_secret_expires_at" {
  description = "应急登录在此之前失效；之前 apply 并重新写入 vault、重跑 gitea.yml。"
  value       = azuread_application_password.gitea.end_date
}
