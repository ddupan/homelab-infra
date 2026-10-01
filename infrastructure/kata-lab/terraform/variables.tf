variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint，不包含 /api2/json。"
  type        = string
  default     = "https://pve1.ad.ddupan.top:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token，格式为 user@realm!token-id=secret。"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "承载 disposable kata-lab VM 的 PVE 节点。"
  type        = string
  default     = "pve2"
}

variable "vm_id" {
  description = "kata-lab VMID。"
  type        = number
  default     = 147
}

variable "vm_name" {
  description = "kata-lab VM 名称和 guest hostname。"
  type        = string
  default     = "kata-lab"
}

variable "vm_memory_mb" {
  description = "VM 固定内存；pve2 只有约 7.4 GiB 可见内存。"
  type        = number
  default     = 4096
}

variable "vm_cores" {
  description = "VM vCPU 数量。"
  type        = number
  default     = 4
}

variable "vm_disk_gb" {
  description = "VM root disk 大小。"
  type        = number
  default     = 41
}

variable "disk_datastore_id" {
  description = "VM root disk 所在 datastore。"
  type        = string
  default     = "pve-rg-hdd"
}

variable "snippet_datastore_id" {
  description = "启用 snippets 的共享 datastore。"
  type        = string
  default     = "laptop"
}

variable "network_bridge" {
  description = "连接 kata-lab VM 的 PVE bridge。"
  type        = string
  default     = "vmbr0"
}

variable "ssh_public_key_file" {
  description = "注入 cloud-init 用户的 SSH 公钥路径。"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "proxmox_ssh_private_key_file" {
  description = "provider 上传 snippet 时登录 PVE 节点使用的私钥路径。"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "k3s_version" {
  description = "可选的固定 k3s 版本；空值使用 stable channel。"
  type        = string
  default     = ""
}
