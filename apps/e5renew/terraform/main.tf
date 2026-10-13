# e5renew's Entra client secret. Entra secrets always expire, so Terraform issues and rotates it
# and writes it to Bao; ESO (../database.yaml) syncs it into the e5renew Secret.
#
# Rotation is apply-driven: time_rotating only fires when someone applies. Run `plan` at least
# once inside the secret_lifetime - secret_rotation_days window (README); on replacement the old
# secret is deleted right after the new one exists, so restart the pod in the same sitting.
data "azuread_client_config" "current" {}

data "azuread_application" "e5renew" {
  client_id = var.client_id
}

resource "time_rotating" "client_secret" {
  rotation_days = var.secret_rotation_days
}

resource "azuread_application_password" "e5renew" {
  application_id = data.azuread_application.e5renew.id
  display_name   = "homelab-terraform ${time_rotating.client_secret.rfc3339}"
  end_date       = timeadd(time_rotating.client_secret.rfc3339, var.secret_lifetime)

  rotate_when_changed = {
    rotation = time_rotating.client_secret.id
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Terraform owns this whole path; app-only values (encryption_key) stay in kv/k8s/e5renew.
resource "vault_kv_secret_v2" "azuread" {
  mount = "kv"
  name  = "k8s/e5renew-azuread"
  data_json = jsonencode({
    tenant_id     = data.azuread_client_config.current.tenant_id
    client_id     = var.client_id
    client_secret = azuread_application_password.e5renew.value
    expires_at    = azuread_application_password.e5renew.end_date
  })
}
