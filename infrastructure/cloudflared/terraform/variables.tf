variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token — scopes: Account·Cloudflare Tunnel:Edit, Zone·DNS:Edit + Zone·SSL and Certificates:Edit (ddupan.top). Provide via TF_VAR_cloudflare_api_token or terraform.tfvars (gitignored)."
}

variable "account_id" {
  type        = string
  default     = "65bf9ede92caa915f992fdf3d1e7b2f1"
  description = "Cloudflare account tag (from the tunnel credentials)."
}

variable "zone_name" {
  type    = string
  default = "ddupan.top"
}

variable "zone_id" {
  type        = string
  description = "Zone ID for ddupan.top (fetch once: GET /zones?name=ddupan.top)."
}

variable "tunnel_id" {
  type        = string
  default     = "ff392451-b0b1-45bb-964e-6d9372c3a9e3"
  description = "Existing cloudflared tunnel ID (remotely managed)."
}
