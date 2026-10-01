provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_file))

    node {
      name    = var.proxmox_node
      address = var.proxmox_node_address
    }
  }
}
