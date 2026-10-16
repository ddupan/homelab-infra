terraform {
  required_version = ">= 1.11.0"

  required_providers {
    sonatyperepo = {
      source  = "sonatype-nexus-community/sonatyperepo"
      version = "1.19.3"
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
  default     = "https://nexus.lab.ddupan.top"
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

variable "dockerhub_username" {
  description = "Docker Hub account the oci-proxy pulls as (public images only)"
  type        = string
}

variable "dockerhub_token" {
  description = "Docker Hub personal access token, Public Repo Read-only"
  type        = string
  sensitive   = true
}

variable "ldap_hostname" {
  description = "AD domain controller serving LDAPS"
  type        = string
  default     = "dc1.ad.ddupan.top"
}

variable "ldap_search_base" {
  description = "AD base DN"
  type        = string
  default     = "DC=ad,DC=ddupan,DC=top"
}

variable "ldap_bind_username" {
  description = "Bind account UPN (svc-nexus; samba-ad keeps it in Bao kv/infra/nexus-ldap)"
  type        = string
}

variable "ldap_bind_password" {
  description = "Bind account password (Bao kv/infra/nexus-ldap)"
  type        = string
  sensitive   = true
}

variable "ldap_admin_group" {
  description = "AD group granted nx-admin"
  type        = string
  default     = "platform-admins"
}

variable "ldap_admin_group_dn" {
  description = "DN of ldap_admin_group, for the login filter"
  type        = string
  default     = "CN=platform-admins,CN=Users,DC=ad,DC=ddupan,DC=top"
}
