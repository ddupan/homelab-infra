provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  # Snippet uploads use SSH. The provider deliberately does not read
  # ~/.ssh/config, so map the PVE node explicitly and use the current agent.
  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_private_key_file))

    node {
      name    = "pve2"
      address = "192.168.10.7"
    }
  }
}
