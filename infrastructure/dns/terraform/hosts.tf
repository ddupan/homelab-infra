# Manual registration: hosts whose parent resource no code creates (bare metal,
# hand-built VMs, a VIP). Where code does create the thing a name points at, the
# record lives with that code instead (incus: ayatori-*, etcd's lxc.yml:
# etcd-pve*); move a record there if its host later gains one.

resource "powerdns_record" "laptop_a" {
  zone    = powerdns_zone.lab.name
  name    = "laptop.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.127"]
}

resource "powerdns_record" "incus_a" {
  zone    = powerdns_zone.lab.name
  name    = "incus.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.127"]
}

resource "powerdns_record" "pg_prod_a" {
  zone    = powerdns_zone.lab.name
  name    = "pg-prod.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.2"]
}

# Patroni dev instance, a host process on the laptop (port 5433).
resource "powerdns_record" "pg_dev_a" {
  zone    = powerdns_zone.lab.name
  name    = "pg-dev.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.127"]
}

resource "powerdns_record" "pve1_a" {
  zone    = powerdns_zone.lab.name
  name    = "pve1.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.4"]
}

resource "powerdns_record" "pve2_a" {
  zone    = powerdns_zone.lab.name
  name    = "pve2.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.7"]
}

# VIP that follows the LINSTOR controller (drbd-reactor promoter, IPaddr2).
resource "powerdns_record" "linstor_controller_a" {
  zone    = powerdns_zone.lab.name
  name    = "linstor-controller.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.3"]
}

resource "powerdns_record" "pve3_a" {
  zone    = powerdns_zone.lab.name
  name    = "pve3.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.9"]
}

resource "powerdns_record" "bao_a" {
  zone    = powerdns_zone.lab.name
  name    = "bao.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.8"]
}

# dc1's AD name is dc1.ad.ddupan.top (Samba's own DNS); this one is its lab name, the
# CN its SPIRE node certificate is issued for (homelab_base: <hostname>.lab.ddupan.top).
resource "powerdns_record" "dc1_a" {
  zone    = powerdns_zone.lab.name
  name    = "dc1.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.5"]
}

resource "powerdns_record" "retrolab_a" {
  zone    = powerdns_zone.lab.name
  name    = "retrolab.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["10.60.0.10"]
}

resource "powerdns_record" "sandbox1_a" {
  zone    = powerdns_zone.lab.name
  name    = "sandbox1.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["10.60.0.11"]
}

resource "powerdns_record" "sandbox2_a" {
  zone    = powerdns_zone.lab.name
  name    = "sandbox2.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["10.60.0.12"]
}

# NixOS 路由器 PoC（infrastructure/router-nixos，vm:105）。地址写在 facts.nix，不走 DHCP；PoC 结束随 VM 删除。
resource "powerdns_record" "router_poc_a" {
  zone    = powerdns_zone.lab.name
  name    = "router-poc.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["10.60.0.40"]
}

# sandbox k3s 入口是 Ayatori LoadBalancer（clusters/ayatori-prod/sandbox-k8s.yaml），VIP 由它分配；
# 这里只把客户端用的名字指向它发布的 Hostname，证书 SAN 与客户端都不随 VIP 改。
# sandbox k3s datastore 入口（clusters/ayatori-prod/sandbox-postgresql.yaml），同上。
resource "powerdns_record" "pg_sandbox_cname" {
  zone    = powerdns_zone.lab.name
  name    = "pg-sandbox.lab.ddupan.top."
  type    = "CNAME"
  ttl     = 300
  records = ["postgresql.sandbox.lb.lab.ddupan.top."]
}

resource "powerdns_record" "sandbox_k8s_cname" {
  zone    = powerdns_zone.lab.name
  name    = "sandbox-k8s.lab.ddupan.top."
  type    = "CNAME"
  ttl     = 300
  records = ["k8s.sandbox.lb.lab.ddupan.top."]
}

# LoadBalancer on the laptop, so external-dns (HTTPRoutes only) cannot publish it.
resource "powerdns_record" "spire_server_a" {
  zone    = powerdns_zone.lab.name
  name    = "spire-server.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.127"]
}

# Also a LoadBalancer on the laptop. NATS is scaled to zero, not retired; the
# record and the cert's lab SAN are ready for re-enabling (platform/nats).
resource "powerdns_record" "nats_a" {
  zone    = powerdns_zone.lab.name
  name    = "nats.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.127"]
}

# SPIRE's SPIFFE Bundle Endpoint behind the Gateway's TLS passthrough listener
# (platform/spire/tlsroute.yaml). Belongs with that TLSRoute, but external-dns 0.23
# watches TLSRoute only as gateway.networking.k8s.io/v1, which this cluster does not
# serve (v1alpha2 only); move it to external-dns once it does.
resource "powerdns_record" "spire_bundle_a" {
  zone    = powerdns_zone.lab.name
  name    = "spire-bundle.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.127"]
}

# Droidian phone (Xperia 5 II) on WiFi; static outside the IX DHCP pool so the
# k3s node-ip pinned on it and the planned TEE-backed seal endpoint stay put.
resource "powerdns_record" "pdx206jp_a" {
  zone    = powerdns_zone.lab.name
  name    = "pdx206jp.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["192.168.10.13"]
}
