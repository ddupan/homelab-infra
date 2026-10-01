output "vm_id" {
  value = proxmox_virtual_environment_vm.kata_lab.vm_id
}

output "vm_ipv4_addresses" {
  description = "QEMU guest agent 报告的地址；忽略 loopback 和 CNI 地址后再用于 SSH。"
  value       = proxmox_virtual_environment_vm.kata_lab.ipv4_addresses
}

output "ssh_user" {
  value = "ansible"
}
