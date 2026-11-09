output "tenant_id" {
  value = data.azuread_client_config.current.tenant_id
}

output "gitea_client_id" {
  value = azuread_application.gitea.client_id
}

output "gitea_client_secret" {
  value     = azuread_application_password.gitea.value
  sensitive = true
}

output "gitea_client_secret_expires_at" {
  description = "应急登录在此之前失效；之前 apply 并重新写入 vault、重跑 gitea.yml。"
  value       = azuread_application_password.gitea.end_date
}

output "onedrive_gateway_client_id" {
  value = azuread_application.onedrive_gateway.client_id
}

output "onedrive_gateway_client_secret" {
  value     = azuread_application_password.onedrive_gateway.value
  sensitive = true
}

output "onedrive_gateway_client_secret_expires_at" {
  description = "到期后 OpenList 无法续 token；之前 apply 并更新管理界面里的 secret。"
  value       = azuread_application_password.onedrive_gateway.end_date
}
