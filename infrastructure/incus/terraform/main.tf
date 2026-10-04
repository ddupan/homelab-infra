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

# 地址只在 records.yml 声明一次，AD DNS（ansible/dns.yml）与此处同源读取；
# 须位于 NEC IX DHCP 池（.128–.250）之外，池由路由器手工维护，无法声明 reservation。
locals {
  ayatori_ipv4 = {
    for r in yamldecode(file("${path.module}/../../dns/records.yml")).homelab_dns.samba.records :
    trimprefix(r.name, "ayatori-") => r.values[0]
    if r.zone == "ad.ddupan.top" && startswith(r.name, "ayatori-")
  }
}

# 镜像不含 openssh-server。不设 ssh_pwauth：它会在装包前写出残缺的 sshd_config，
# 使包自带的默认配置（UsePAM yes、Include sshd_config.d）无法落地，锁定密码的账号随即被拒。
# 改为装包后（defer）再写 drop-in，只覆盖需要收紧的项。
locals {
  ayatori_cloud_config = {
    manage_etc_hosts = true
    disable_root     = true
    users = [{
      name                = "panxiao81"
      groups              = ["sudo"]
      shell               = "/bin/bash"
      sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
      lock_passwd         = true
      ssh_authorized_keys = [trimspace(file("${path.module}/../ansible/files/panxiao81.pub"))]
    }]
    # WAN 随机掉线，装包须重试。
    apt            = { conf = "Acquire::Retries \"5\";" }
    package_update = true
    packages       = ["openssh-server"]
    write_files = [{
      path    = "/etc/ssh/sshd_config.d/60-homelab.conf"
      defer   = true
      content = <<-EOT
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
      EOT
    }]
  }
}

resource "incus_instance" "ayatori" {
  for_each    = toset(["dev", "prod"])
  name        = "ayatori-${each.key}"
  description = "Ayatori ${each.key} 基础容器；应用由独立部署流程管理"
  # 跟随 24.04 cloud 最新构建：同一发行版的构建只差安全更新，固定指纹会随上游下架而无法重建。
  image    = "images:ubuntu/24.04/cloud"
  type     = "container"
  profiles = []
  running  = true
  config = {
    "boot.autostart"      = "true"
    "security.privileged" = "false"
    # Ayatori 控制面以 podman quadlet 运行 ESO、Flux 与 manager；非特权容器内创建容器
    # 需要嵌套。该键不经 cloud-init，修改后重启实例即生效，无需重建。
    "security.nesting"   = "true"
    "limits.cpu"         = "2"
    "limits.memory"      = "2GiB"
    "limits.memory.swap" = "false"
    # ⚠ 镜像模板只在 create/copy 时渲染 cloud-init seed（when: [create, copy]），
    # 对已有实例修改此键不会生效，重启或 cloud-init clean 也不会；改地址须重建实例。
    # 网关与 resolver 沿用 LAN DHCP 下发值：.1 网关；Blocky .127 优先、路由器 .1 兜底。
    "cloud-init.network-config" = yamlencode({
      version = 2
      ethernets = {
        eth0 = {
          addresses   = ["${local.ayatori_ipv4[each.key]}/24"]
          routes      = [{ to = "default", via = "192.168.10.1" }]
          nameservers = { addresses = ["192.168.10.127", "192.168.10.1"] }
        }
      }
    })
    "cloud-init.user-data" = "#cloud-config\n${yamlencode(merge(local.ayatori_cloud_config, {
      hostname = "ayatori-${each.key}"
    }))}"
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
    # 镜像只在创建时使用；provider 按字符串比较，改写它不应触发重建现有实例。
    ignore_changes  = [image]
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
