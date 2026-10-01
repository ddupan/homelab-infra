locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_file)))
}

data "proxmox_file" "ubuntu_noble" {
  content_type = "vztmpl"
  datastore_id = var.template_datastore
  node_name    = var.proxmox_node
  file_name    = var.template_file_name
}

resource "proxmox_virtual_environment_container" "kata_lxc_lab" {
  node_name = var.proxmox_node
  vm_id     = var.container_id

  description   = "Disposable privileged LXC for validating k3s and Kata with direct host KVM access."
  unprivileged  = false
  started       = true
  start_on_boot = false
  tags          = ["disposable", "kata", "lxc", "terraform"]

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
    swap      = 0
  }

  disk {
    datastore_id = var.root_datastore
    size         = 16
  }

  features {
    fuse    = true
    keyctl  = true
    mknod   = true
    nesting = true
  }

  device_passthrough {
    path = "/dev/kvm"
    mode = "0660"
  }

  device_passthrough {
    path = "/dev/vhost-net"
    mode = "0660"
  }

  device_passthrough {
    path = "/dev/vhost-vsock"
    mode = "0660"
  }

  device_passthrough {
    path = "/dev/kmsg"
    mode = "0660"
  }

  device_passthrough {
    path = "/dev/net/tun"
    mode = "0666"
  }

  initialization {
    hostname = var.container_name

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      keys = [local.ssh_public_key]
    }
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = data.proxmox_file.ubuntu_noble.id
    type             = "ubuntu"
  }

  wait_for_ip {
    ipv4 = true
  }
}
