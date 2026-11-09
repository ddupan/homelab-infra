terraform {
  required_version = ">= 1.5"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

# Azure CLI auth (`az login`)。不进 CI 的 TF_ROOTS：与 e5renew / smtp-relay 同理，CI 没有可用的
# Azure 身份（尚未配置 Entra 与 runner JWT-SVID 的联合）。
provider "azuread" {}
