terraform {
  required_version = ">= 1.10.0"
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "1.2.1"
    }
    # Same provider and pin as infrastructure/dns/terraform.
    powerdns = { source = "mmianl/powerdns", version = "~> 2.5" }
  }
}

# laptop 上默认走本机 Unix socket；CI 由 .gitea/scripts/tf.py 改为 HTTPS，并给出
# 临时 config_dir：内含 Bao pki-incus 签发的 30 分钟客户端证书，以及 server.crt
# （servercerts/local.crt，固定校验 Incus 自签服务器证书，不做首次信任）。
variable "incus_address" {
  type    = string
  default = "unix://"
}

variable "incus_config_dir" {
  type    = string
  default = null
}

# API key from PDNS_API_KEY (tf.py in CI, run.py locally), as in the dns root.
provider "powerdns" {
  server_url = "http://192.168.10.127:8053"
}

provider "incus" {
  default_remote = "local"
  config_dir     = var.incus_config_dir
  remote {
    name    = "local"
    address = var.incus_address
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

resource "incus_storage_volume" "ayatori_backup" {
  for_each = toset(["dev", "prod"])
  name     = "ayatori-${each.key}-backup"
  pool     = incus_storage_pool.ayatori.name
  config = {
    size = "2GiB"
  }
  lifecycle {
    prevent_destroy = true
  }
}

# 地址在此声明，并由本 root 注册 lab.ddupan.top 记录：谁创建资源谁注册名字。
# 须位于 NEC IX DHCP 池（.128–.250）之外，池由路由器手工维护，无法声明 reservation。
# 新地址先用 infrastructure/dns/generate.py --next-free 查空闲。
locals {
  ayatori_ipv4 = {
    dev  = "192.168.10.11"
    prod = "192.168.10.12"
  }
}

resource "powerdns_record" "ayatori" {
  for_each = local.ayatori_ipv4
  zone     = "lab.ddupan.top."
  name     = "ayatori-${each.key}.lab.ddupan.top."
  type     = "A"
  ttl      = 300
  records  = [each.value]
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
    # 整机快照只防误操作并支持快速回滚，与实例同池，不能代替 k0s backup。
    "snapshots.schedule" = "@daily"
    "snapshots.expiry"   = "7d"
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
  # k0s backup 写入独立 custom volume：离开容器 rootfs，重建实例不丢失；与实例同池，不是离机备份。
  device {
    name = "backup"
    type = "disk"
    properties = {
      path   = "/var/backups/ayatori"
      pool   = incus_storage_pool.ayatori.name
      source = incus_storage_volume.ayatori_backup[each.key].name
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
