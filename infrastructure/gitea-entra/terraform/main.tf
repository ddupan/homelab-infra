# Gitea（oci-arm）的第二登录源。iam-login（sso.ddupan.top）依赖 lab 里的 dc1；lab 挂掉时仍要能登录
# Gitea 拿到 repo——恢复路径的第一步就是它（docs/gitea-oci-migration-plan.md）。
#
# secret 去向刻意不是 Bao：Bao 也在 lab 里。apply 后把 client_secret 写进
# infrastructure/oci/ansible/host_vars/oci_arm/vault.yml（vault_gitea_entra_client_secret），再跑 gitea.yml（README）。
data "azuread_client_config" "current" {}

data "azuread_user" "admin" {
  user_principal_name = var.admin_upn
}

resource "azuread_application" "gitea" {
  display_name     = "Gitea (git.ddupan.top)"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  web {
    # 路径里的 entra 是 Gitea 登录源名（roles/gitea defaults 的 gitea_entra_source_name），改名要同时改这里。
    redirect_uris = ["https://git.ddupan.top/user/oauth2/entra/callback"]
  }

  # Gitea 的 ACCOUNT_LINKING = auto 按 email 关联已有账号；托管用户的 v2 ID token 默认不带 email。
  optional_claims {
    id_token {
      name = "email"
    }
  }
}

# assignment required：租户里只有被分配的人能登录，否则任何 ddupan.top 账号都会被 Gitea 自动注册。
resource "azuread_service_principal" "gitea" {
  client_id                    = azuread_application.gitea.client_id
  app_role_assignment_required = true
  owners                       = [data.azuread_client_config.current.object_id]
}

resource "azuread_app_role_assignment" "admin" {
  app_role_id         = "00000000-0000-0000-0000-000000000000" # Default Access
  principal_object_id = data.azuread_user.admin.object_id
  resource_object_id  = azuread_service_principal.gitea.object_id
}

# 与 e5renew 相同的 apply 驱动轮换。区别：这是应急入口，平时没人用，过期了也不会有人发现——
# 所以有效期留得长，并在 README 里记到期日。
resource "time_rotating" "client_secret" {
  rotation_days = var.secret_rotation_days
}

resource "azuread_application_password" "gitea" {
  application_id = azuread_application.gitea.id
  display_name   = "homelab-terraform ${time_rotating.client_secret.rfc3339}"
  end_date       = timeadd(time_rotating.client_secret.rfc3339, var.secret_lifetime)

  rotate_when_changed = {
    rotation = time_rotating.client_secret.id
  }

  lifecycle {
    create_before_destroy = true
  }
}
