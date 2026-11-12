# Remote state like the other roots (see apps/seaweedfs/terraform/backend.tf). Client secrets
# obtained by this root end up in state; the tfstate bucket is readable only by the terraform and read-only tfstate-backup identities.
terraform {
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "iam-login/terraform.tfstate"
    endpoints                   = { s3 = "https://s3.lab.ddupan.top" }
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
