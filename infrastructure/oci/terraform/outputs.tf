output "instance_id" {
  value = oci_core_instance.vm.id
}

output "instance_private_ip" {
  value = oci_core_instance.vm.private_ip
}

output "instance_public_ip" {
  value = oci_core_instance.vm.public_ip
}

output "ssh_command" {
  value = "ssh ubuntu@${oci_core_instance.vm.public_ip}"
}

