variable "bao_address" {
  type        = string
  default     = "https://bao.ad.ddupan.top:8200"
  description = <<-EOT
    OpenBao API address. Must be the name clients can actually reach and verify:
    it is baked into ACME directory URLs and issued certs' AIA extension.
  EOT
}

variable "pki_mount" {
  type        = string
  default     = "pki"
  description = "Path of the PKI secrets engine. Mount itself is Ansible-owned (openbao_bootstrap)."
}

variable "acme_enabled" {
  type        = bool
  default     = true
  description = "Enable the ACME directory on the PKI mount."
}

variable "acme_role" {
  type        = string
  default     = "bao-server"
  description = <<-EOT
    Role that constrains ACME issuance. Its allowed_domains cap what any ACME
    client can obtain — currently ad.ddupan.top with subdomains, IP SANs allowed.
    NEVER leave the policy as sign-verbatim; that would let ACME issue any name.
  EOT
}

variable "acme_eab_policy" {
  type        = string
  default     = "not-required"
  description = <<-EOT
    "not-required": any host reaching bao may enroll (names still capped by acme_role).
    "new-account-required": each client must present an External Account Binding
    credential from `bao write -f pki/acme/new-eab`. Tighter, but needs per-host
    provisioning and rotation.
  EOT
  validation {
    condition     = contains(["not-required", "new-account-required", "always-required"], var.acme_eab_policy)
    error_message = "Must be not-required, new-account-required, or always-required."
  }
}
