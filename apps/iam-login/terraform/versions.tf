terraform {
  required_version = ">= 1.11.0"

  required_providers {
    homelab = {
      # Our own provider, served by the static registry in apps/seaweedfs (releases signed on the
      # maintainer's YubiKey). See git.ddupan.top/panxiao81/terraform-provider-homelab.
      source  = "terraform.lab.ddupan.top/ddupan/homelab"
      version = "~> 0.2"
    }
    # Client secrets go straight to bao for the apps' ExternalSecrets; CD's ci-terraform token covers kv.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# No credentials: every call carries a JWT-SVID (audience iam-login) of whoever runs Terraform. CD's
# terraform-plan / terraform-apply jobs and the laptop's development identity are on iam-login's
# allowlist (../application.yaml, iam.clients.spiffe.admin-ids). Same socket path in both CI pod pools.
provider "homelab" {
  iam_login              = { endpoint = "https://sso.ddupan.top" }
  spiffe_endpoint_socket = "unix:///run/spire/agent-sockets/spire-agent.sock"
}

# Token from the environment (CD: spiffe-openbao-login; locally: bao login). By hostname: the cert has no IP SAN.
provider "vault" {
  address = "https://bao.lab.ddupan.top:8200"
}
