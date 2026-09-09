output "acme_directory_url" {
  value       = "${var.bao_address}/v1/${var.pki_mount}/roles/${var.acme_role}/acme/directory"
  description = <<-EOT
    Point ACME clients here. Example, on dc1 (binds :80 only during renewal):
      lego --server <this> --domains dc1.ad.ddupan.top --email admin@ddupan.top --http run
    Clients must already trust the internal CA, or pass its PEM to the client.
  EOT
}

output "acme_enabled" {
  value       = vault_pki_secret_backend_config_acme.this.enabled
  description = "Whether the ACME directory is currently serving."
}
