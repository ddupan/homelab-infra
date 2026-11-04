resource "oci_core_instance" "vm" {
  agent_config {
    are_all_plugins_disabled = false
    is_management_disabled   = false
    is_monitoring_disabled   = false
  }
  availability_config {
    is_live_migration_preferred = false
    recovery_action             = "RESTORE_INSTANCE"
  }
  availability_domain = "diPX:AP-OSAKA-1-AD-1"
  compartment_id      = var.compartment_ocid
  create_vnic_details {
    assign_private_dns_record = false
    assign_public_ip          = "true"
    display_name              = "homelab-vm"
    nsg_ids                   = [oci_core_network_security_group.gitea.id]
    hostname_label            = "homelab-vm"
    private_ip                = "10.0.0.124"
    skip_source_dest_check    = false
    subnet_id                 = oci_core_subnet.public.id
  }
  display_name = "homelab-vm"
  fault_domain = "FAULT-DOMAIN-1"
  instance_options {
    are_legacy_imds_endpoints_disabled = false
  }
  launch_options {
    boot_volume_type                    = "PARAVIRTUALIZED"
    firmware                            = "UEFI_64"
    is_consistent_volume_naming_enabled = true
    is_pv_encryption_in_transit_enabled = false
    network_type                        = "PARAVIRTUALIZED"
    remote_data_volume_type             = "PARAVIRTUALIZED"
  }
  metadata = var.instance_metadata
  shape    = "VM.Standard.A1.Flex"
  shape_config {
    memory_in_gbs = 12
    ocpus         = 2
  }
  source_details {
    boot_volume_size_in_gbs = "100"
    boot_volume_vpus_per_gb = "10"
    source_id               = var.image_ocid
    source_type             = "image"
  }

  # 原生命周期配置不可恢复；保护现有 VM，避免重建丢失系统盘数据。
  lifecycle {
    prevent_destroy = true
  }
}

