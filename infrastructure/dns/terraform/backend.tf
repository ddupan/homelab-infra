# Remote state in SeaweedFS S3, like every CI-applied root. See
# ../../cloudflared/terraform/backend.tf for why s3.lab.ddupan.top and the skips.
terraform {
  backend "s3" {
    bucket = "tfstate"
    key    = "dns/terraform.tfstate"
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
