# Entra app registration for the Postfix sasl-xoauth2 relay.
# Delegated Microsoft Graph SMTP.Send + admin consent + a client secret. The relay
# still needs a one-time device-code login to mint the refresh token (see ../README.md).

data "azuread_client_config" "current" {}

# Microsoft Graph well-known IDs, so we don't hardcode the SMTP.Send permission UUID.
data "azuread_application_published_app_ids" "well_known" {}

resource "azuread_service_principal" "msgraph" {
  client_id    = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
  use_existing = true
}

resource "azuread_application" "smtp_relay" {
  display_name     = var.app_display_name
  sign_in_audience = "AzureADMyOrg"

  # Enables "Allow public client flows" so the device-code flow works, while we still
  # keep a client secret for confidential refresh.
  fallback_public_client_enabled = true

  public_client {
    redirect_uris = ["https://login.microsoftonline.com/common/oauth2/nativeclient"]
  }

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]

    resource_access {
      id   = azuread_service_principal.msgraph.oauth2_permission_scope_ids["SMTP.Send"]
      type = "Scope" # delegated
    }
  }
}

resource "azuread_service_principal" "smtp_relay" {
  client_id = azuread_application.smtp_relay.client_id
}

# NOTE: no client secret. This is a PUBLIC client (device-code delegated flow); the
# refresh token is the credential. Presenting a secret makes Entra reject the refresh
# with AADSTS700025 ("Client is public..."). CLIENT_SECRET in the k8s secret is empty.

# Org-wide admin consent for the delegated SMTP.Send scope (no per-user consent prompt).
resource "azuread_service_principal_delegated_permission_grant" "smtp_send" {
  service_principal_object_id          = azuread_service_principal.smtp_relay.object_id
  resource_service_principal_object_id = azuread_service_principal.msgraph.object_id
  claim_values                         = ["SMTP.Send"]
}
