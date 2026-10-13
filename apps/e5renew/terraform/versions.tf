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
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Azure CLI auth (`az login`): needs an account that owns the e5renew app registration.
# Not in CI's TF_ROOTS for the same reason as smtp-relay: there is no Azure identity CI could use
# (spire-oidc is LAN-only, so Entra cannot federate with the runners' JWT-SVIDs).
provider "azuread" {}

provider "vault" {
  address = "https://bao.lab.ddupan.top:8200"
  # The wrapper's short-lived token; it revokes it afterwards, so no child token is needed.
  skip_child_token = true
}
