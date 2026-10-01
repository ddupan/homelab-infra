variable "proxmox_endpoint" {
  type    = string
  default = "https://pve1.ad.ddupan.top:8006"
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type    = string
  default = "pve2"
}

variable "proxmox_node_address" {
  type    = string
  default = "192.168.10.7"
}

variable "proxmox_ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "container_id" {
  type    = number
  default = 147
}

variable "container_name" {
  type    = string
  default = "kata-lxc-lab"
}

variable "template_datastore" {
  type    = string
  default = "laptop"
}

variable "template_file_name" {
  type    = string
  default = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "root_datastore" {
  type    = string
  default = "local-lvm"
}
