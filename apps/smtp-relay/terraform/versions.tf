terraform {
  required_version = ">= 1.5"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

# Authenticates via Azure CLI by default: run `az login` as an account that can
# create app registrations AND grant admin consent (Global Admin / Privileged Role
# Admin) before `terraform apply`.
provider "azuread" {}
