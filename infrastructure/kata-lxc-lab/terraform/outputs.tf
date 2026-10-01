output "container_id" {
  value = proxmox_virtual_environment_container.kata_lxc_lab.vm_id
}

output "ipv4" {
  value = proxmox_virtual_environment_container.kata_lxc_lab.ipv4
}
