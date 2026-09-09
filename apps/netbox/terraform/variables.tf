variable "netbox_url" {
  type        = string
  description = "Base URL of NetBox, WITHOUT the /api suffix."
  default     = "https://netbox.ad.ddupan.top"
}

variable "netbox_token" {
  type        = string
  sensitive   = true
  description = <<-EOT
    NetBox API token. A v2 token (nbt_<key>.<secret>) works fine — NetBox dispatches on the
    token value, not the Authorization scheme. Mint one with the snippet in ../README.md.
    Supply via TF_VAR_netbox_token or terraform.tfvars (gitignored).
  EOT
}
