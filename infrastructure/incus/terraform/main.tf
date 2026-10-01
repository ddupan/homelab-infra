terraform {
  required_version = ">= 1.10.0"
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "1.2.0"
    }
  }
}

provider "incus" {
  default_remote = "local"
  remote {
    name    = "local"
    address = "unix://"
  }
  remote {
    name     = "images"
    address  = "https://images.linuxcontainers.org"
    protocol = "simplestreams"
    public   = true
  }
}

# 专用子 dataset，不接管整个宿主 data 池。
resource "incus_storage_pool" "ayatori" {
  name   = "ayatori"
  driver = "zfs"
  config = {
    source = "data/incus-ayatori"
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "incus_instance" "ayatori" {
  for_each    = toset(["dev", "prod"])
  name        = "ayatori-${each.key}"
  description = "Ayatori ${each.key} 基础容器；应用由独立部署流程管理"
  # Ubuntu 24.04 cloud amd64，20260924_07:42；固定指纹避免重建时静默更换镜像。
  image    = "images:b39d3d56c30738ad74c507066cc5d410e1c0f1647bdcdff398be1ee51d63862a"
  type     = "container"
  profiles = []
  running  = true
  config = {
    "boot.autostart"      = "true"
    "security.privileged" = "false"
    "security.nesting"    = "false"
    "limits.cpu"          = "2"
    "limits.memory"       = "2GiB"
    "limits.memory.swap"  = "false"
    "cloud-init.user-data" = "#cloud-config\n${yamlencode({
      hostname         = "ayatori-${each.key}"
      manage_etc_hosts = true
      ssh_pwauth       = false
      disable_root     = true
      users = [{
        name                = "panxiao81"
        groups              = ["sudo"]
        shell               = "/bin/bash"
        sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
        lock_passwd         = true
        ssh_authorized_keys = [trimspace(file("${path.module}/../ansible/files/panxiao81.pub"))]
      }]
    })}"
  }
  device {
    name = "root"
    type = "disk"
    properties = {
      path = "/"
      pool = incus_storage_pool.ayatori.name
      size = "20GiB"
    }
  }
  device {
    name = "eth0"
    type = "nic"
    properties = {
      name    = "eth0"
      nictype = "bridged"
      parent  = "br0"
      hwaddr  = each.key == "dev" ? "02:16:3e:aa:00:01" : "02:16:3e:aa:00:02"
    }
  }
  wait_for {
    type = "ipv4"
    nic  = "eth0"
  }
  lifecycle {
    prevent_destroy = true
  }
}

output "containers" {
  value = { for env, instance in incus_instance.ayatori : env => {
    name = instance.name
    ipv4 = instance.ipv4_address
    mac  = instance.mac_address
  } }
}
