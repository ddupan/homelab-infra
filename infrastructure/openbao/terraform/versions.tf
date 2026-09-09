terraform {
  required_version = ">= 1.5"
  required_providers {
    # NOTE: this targets OpenBao, but uses the HASHICORP VAULT provider.
    # The native `openbao/openbao` provider is published to the OpenTofu
    # registry, NOT registry.terraform.io, so it cannot be resolved by the
    # HashiCorp `terraform` CLI in use here ("provider registry
    # registry.terraform.io does not have a provider named openbao/openbao").
    # OpenBao is API-compatible with Vault, so this provider drives it fine.
    # If this repo ever switches to `tofu`, swap to openbao/openbao and rename
    # the vault_* resources to openbao_*.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Authenticates from the ambient CLI session, same pattern as smtp-relay/terraform
# uses `az login`: run `bao login -method=oidc` first, which writes ~/.vault-token.
# VAULT_ADDR/VAULT_TOKEN (or BAO_ADDR/BAO_TOKEN exported into them) override.
# No credentials are stored in this config.
provider "vault" {
  address = var.bao_address
}
