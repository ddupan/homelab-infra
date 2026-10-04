terraform {
  required_version = ">= 1.11.0"

  required_providers {
    sonatyperepo = {
      source  = "sonatype-nexus-community/sonatyperepo"
      version = "1.17.0"
    }
  }
}

provider "sonatyperepo" {
  url      = var.nexus_url
  username = var.nexus_username
  password = var.nexus_password
}

variable "nexus_url" {
  description = "Nexus Repository base URL"
  type        = string
  default     = "https://nexus.ad.ddupan.top"
}

variable "nexus_username" {
  description = "Nexus Terraform management username"
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "nexus_password" {
  description = "Nexus Terraform management password"
  type        = string
  sensitive   = true
}
