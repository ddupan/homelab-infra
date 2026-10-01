locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname       = var.vm_name
    ssh_public_key = local.ssh_public_key
    k3s_version    = var.k3s_version
  })
}

data "proxmox_file" "ubuntu_noble" {
  content_type = "import"
  datastore_id = var.snippet_datastore_id
  node_name    = var.node_name
  file_name    = "noble-server-cloudimg-amd64.qcow2"
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.snippet_datastore_id
  node_name    = var.node_name

  source_raw {
    data      = local.cloud_init
    file_name = "${var.vm_name}-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "kata_lab" {
  name        = var.vm_name
  description = "Disposable single-node k3s and Kata Containers validation environment."
  tags        = ["terraform", "disposable", "kata"]

  node_name = var.node_name
  vm_id     = var.vm_id

  started         = true
  on_boot         = false
  stop_on_destroy = true

  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores = var.vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  operating_system {
    type = "l26"
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = var.disk_datastore_id
    import_from  = data.proxmox_file.ubuntu_noble.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = var.vm_disk_gb
  }

  initialization {
    datastore_id      = var.disk_datastore_id
    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  serial_device {}
}
