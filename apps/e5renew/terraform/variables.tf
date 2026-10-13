variable "client_id" {
  description = "Client ID of the e5renew app registration (created by hand; Terraform owns only its secret)."
  type        = string
  default     = "a5cecb07-fc6b-48e6-96a7-8d6135d3acca"
}

variable "secret_rotation_days" {
  description = "A new client secret is issued on the first apply after this many days."
  type        = number
  default     = 300
}

variable "secret_lifetime" {
  description = "Validity of each client secret (Entra caps secrets; it must outlast rotation_days plus the time until someone applies)."
  type        = string
  default     = "8760h" # 365 days: leaves 65 days after rotation is due
}
