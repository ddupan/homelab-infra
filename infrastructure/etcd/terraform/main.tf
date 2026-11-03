terraform {
  required_version = ">= 1.10"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "vault" {
  address = var.bao_address
}

variable "bao_address" {
  type    = string
  default = "https://bao.lab.ddupan.top:8200"
}
variable "pki_mount" {
  type    = string
  default = "pki"
}
variable "kv_mount" {
  type    = string
  default = "kv"
}
variable "member_names" {
  type    = list(string)
  default = ["etcd-laptop", "etcd-pve1", "etcd-pve2"]
}
variable "consumer_names" {
  type    = set(string)
  default = ["patroni-pg-prod", "patroni-pg-sandbox"]
}

# 仅管理既有 PKI 下的新 role/policy，不纳管 CA 私钥、mount 或秘密值。
locals {
  certificate_roles = {
    server  = { names = var.member_names, server = true, client = false, ips = true }
    peer    = { names = concat(var.member_names, ["homelab-etcd-peer"]), server = true, client = true, ips = true }
    admin   = { names = ["root"], server = false, client = true, ips = false }
    gateway = { names = var.member_names, server = false, client = true, ips = false }
    client  = { names = [for name in var.consumer_names : "etcd-${name}"], server = false, client = true, ips = false }
  }
}
resource "vault_pki_secret_backend_role" "etcd" {
  for_each                    = local.certificate_roles
  backend                     = var.pki_mount
  name                        = "homelab-etcd-${each.key}"
  allowed_domains             = each.value.names
  allow_bare_domains          = true
  allow_subdomains            = false
  allow_glob_domains          = false
  allow_any_name              = false
  allow_localhost             = false
  allow_wildcard_certificates = false
  allow_ip_sans               = each.value.ips
  server_flag                 = each.value.server
  client_flag                 = each.value.client
  key_type                    = "ec"
  key_bits                    = 256
  ttl                         = 5184000
  max_ttl                     = 5184000
  require_cn                  = !contains(["gateway", "client"], each.key)
  use_csr_common_name         = true
  use_csr_sans                = true
}

resource "vault_policy" "etcd_provisioner" {
  name   = "homelab-etcd-provisioner"
  policy = <<-EOT
    path "${var.pki_mount}/sign/homelab-etcd-*" {
      capabilities = ["update"]
    }
    path "${var.kv_mount}/metadata/infra/etcd/consumers/*" {
      capabilities = ["read"]
    }
    path "${var.kv_mount}/data/infra/etcd/consumers/*" {
      capabilities = ["create", "read", "update"]
    }
  EOT
}

# 身份绑定沿用既有控制端认证方式，创建 policy 不自动授权任何身份。
resource "vault_policy" "etcd_consumer" {
  for_each = var.consumer_names
  name     = "homelab-etcd-${each.key}"
  policy   = <<-EOT
    path "${var.kv_mount}/data/infra/etcd/consumers/${each.key}" {
      capabilities = ["read"]
    }
  EOT
}
