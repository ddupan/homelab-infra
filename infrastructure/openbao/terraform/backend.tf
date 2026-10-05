# Remote state in SeaweedFS S3, on the LAN.
#
# WHY remote at all: local state means the only copy lives on this laptop, which is
# also the k3s node, the NFS server and the libvirt host — i.e. the single point of
# failure. It also cannot be locked, so two concurrent applies silently corrupt it.
#
# WHY s3.lab.ddupan.top and NOT obj.ddupan.top: the public name resolves to
# Cloudflare and hairpins through the WAN. On 2026-07-28 that path was blackholed
# for hours by a dead VPN tunnel. State must be reachable when the WAN is not —
# it is what you need DURING an incident. See ../../../apps/seaweedfs/httproute-s3.yaml.
#
# CREDENTIALS are not in this file. Export them before running terraform:
#   export AWS_ACCESS_KEY_ID=$(bao kv get -field=... kv/k8s/seaweedfs-s3)   # see README
#   export AWS_SECRET_ACCESS_KEY=...
# The `terraform` S3 identity is scoped to this bucket only — it deliberately
# cannot create buckets or read anything else in the store.
terraform {
  backend "s3" {
    bucket = "tfstate"
    key    = "openbao/terraform.tfstate"

    endpoints = {
      s3 = "https://s3.lab.ddupan.top"
    }

    # SeaweedFS is not AWS: it has no regions, no IAM, no metadata service and no
    # account IDs, so every AWS-specific validation has to be skipped or the
    # provider fails before it ever talks to the endpoint.
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true

    # Native S3 locking (Terraform >= 1.10; this repo runs 1.15). Writes a
    # .tflock object alongside the state — no DynamoDB table needed.
    use_lockfile = true
  }
}
