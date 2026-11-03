terraform {
  required_version = ">= 1.5"
  required_providers {
    # NOTE: this targets OpenBao, but uses the HASHICORP VAULT provider: OpenBao has no
    # provider of its own yet (checked 2026-11-03 — nothing on registry.opentofu.org or in the
    # openbao GitHub org). RFC "Dedicated OpenTofu/Terraform provider" (openbao/openbao#3720,
    # accepted 2026-09) plans a low-divergence fork of this provider, published to BOTH the
    # Terraform and OpenTofu registries with the same vault_* resource names; switching will
    # then be a source change plus `terraform state replace-provider`, no tofu migration.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
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
