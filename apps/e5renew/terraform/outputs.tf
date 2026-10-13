output "client_secret_expires_at" {
  description = "When the current client secret expires; apply (and restart the pod) before then."
  value       = azuread_application_password.e5renew.end_date
}

output "client_secret_rotation_due" {
  description = "From this time the next apply issues a new secret."
  value       = time_rotating.client_secret.rotation_rfc3339
}
