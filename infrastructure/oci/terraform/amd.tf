# E2 Micro 使用独立的 x86_64 镜像；固定版本以免镜像目录更新触发重建。
resource "oci_core_instance" "amd" {
  availability_domain = oci_core_instance.vm.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "homelab-amd"
  shape               = "VM.Standard.E2.1.Micro"

  create_vnic_details {
    subnet_id              = oci_core_subnet.public.id
    skip_source_dest_check = true
    nsg_ids                = [oci_core_network_security_group.wireguard.id]
    assign_public_ip       = true
    hostname_label         = "homelab-amd"
    display_name           = "homelab-amd"
  }

  # 仅复用登录公钥，不复制原实例可能新增的 user_data 等初始化内容。
  metadata = {
    ssh_authorized_keys = var.instance_metadata["ssh_authorized_keys"]
  }

  source_details {
    source_type             = "image"
    source_id               = "ocid1.image.oc1.ap-osaka-1.aaaaaaaap3ki4u45x7acf3q3upe6sudoe4l3ogin55dmgp3gye6lvhhjg6mq"
    boot_volume_size_in_gbs = 50
    boot_volume_vpus_per_gb = 10
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "amd_instance_id" {
  value = oci_core_instance.amd.id
}
output "amd_private_ip" {
  value = oci_core_instance.amd.private_ip
}
output "amd_public_ip" {
  value = oci_core_instance.amd.public_ip
}
output "amd_ssh_command" {
  value = "ssh ubuntu@${oci_core_instance.amd.public_ip}"
}
