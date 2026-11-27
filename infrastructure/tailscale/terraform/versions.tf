terraform {
  required_version = ">= 1.6"
  required_providers {
    tailscale = { source = "tailscale/tailscale", version = "~> 0.30" }
  }
  # Remote state in SeaweedFS S3, like every CI-applied root. See
  # ../../cloudflared/terraform/backend.tf for why s3.lab.ddupan.top and the skips.
  backend "s3" {
    bucket = "tfstate"
    key    = "tailscale/terraform.tfstate"
    endpoints = {
      s3 = "https://s3.lab.ddupan.top"
    }
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}

# No credential in code or Bao. In CI the provider exchanges the job's GitHub OIDC token itself
# (TAILSCALE_OAUTH_CLIENT_ID + TAILSCALE_AUDIENCE from terraform.yml, one federated identity per
# job, defined below). Locally: TAILSCALE_API_KEY, which is also the lock-out recovery path if an
# apply ever breaks CI's own identities or the tag:ci rules it reaches the LAN through.
provider "tailscale" {}
