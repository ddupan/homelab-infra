# OpenList（apps/openlist）访问专用账号 OneDrive 用的应用。用委托权限而不是应用权限：应用权限能读写
# 租户里所有人的文件，委托权限只到登录的这个账号，.All 也只是它自己能访问的范围。
# 账号和授权手工建（README）：azuread provider 分配不了许可证，5 TB 配额也不归它管。
data "azuread_user" "onedrive_gateway" {
  user_principal_name = var.onedrive_gateway_upn
}

data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "graph" {
  client_id = data.azuread_application_published_app_ids.well_known.result["MicrosoftGraph"]
}

locals {
  # rclone authorize 请求的范围，少一个就会卡在同意页面。
  onedrive_gateway_scopes = ["Files.Read", "Files.ReadWrite", "Files.Read.All", "Files.ReadWrite.All", "Sites.Read.All", "offline_access"]
}

resource "azuread_application" "onedrive_gateway" {
  display_name     = "OneDrive gateway (OpenList)"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  web {
    # rclone authorize 的本地回调，只在取 refresh token 时用。
    redirect_uris = ["http://localhost:53682/"]
  }

  required_resource_access {
    resource_app_id = data.azuread_service_principal.graph.client_id

    dynamic "resource_access" {
      for_each = local.onedrive_gateway_scopes
      content {
        id   = data.azuread_service_principal.graph.oauth2_permission_scope_ids[resource_access.value]
        type = "Scope"
      }
    }
  }
}

# assignment required：只有专用账号能登录这个应用。
resource "azuread_service_principal" "onedrive_gateway" {
  client_id                    = azuread_application.onedrive_gateway.client_id
  app_role_assignment_required = true
  owners                       = [data.azuread_client_config.current.object_id]
}

resource "azuread_app_role_assignment" "onedrive_gateway" {
  app_role_id         = "00000000-0000-0000-0000-000000000000" # Default Access
  principal_object_id = data.azuread_user.onedrive_gateway.object_id
  resource_object_id  = azuread_service_principal.onedrive_gateway.object_id
}

# 同意只授给专用账号，不是全租户。
resource "azuread_service_principal_delegated_permission_grant" "onedrive_gateway" {
  service_principal_object_id          = azuread_service_principal.onedrive_gateway.object_id
  resource_service_principal_object_id = data.azuread_service_principal.graph.object_id
  claim_values                         = local.onedrive_gateway_scopes
  user_object_id                       = data.azuread_user.onedrive_gateway.object_id
}

resource "time_rotating" "onedrive_gateway_client_secret" {
  rotation_days = var.onedrive_gateway_secret_rotation_days
}

resource "azuread_application_password" "onedrive_gateway" {
  application_id = azuread_application.onedrive_gateway.id
  display_name   = "homelab-terraform ${time_rotating.onedrive_gateway_client_secret.rfc3339}"
  end_date       = timeadd(time_rotating.onedrive_gateway_client_secret.rfc3339, var.onedrive_gateway_secret_lifetime)

  rotate_when_changed = {
    rotation = time_rotating.onedrive_gateway_client_secret.id
  }

  lifecycle {
    create_before_destroy = true
  }
}
