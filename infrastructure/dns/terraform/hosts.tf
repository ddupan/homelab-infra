# Manual registration: hosts whose parent resource no code creates (bare metal,
# hand-built VMs, a VIP). Where code does create the thing a name points at, the
# record lives with that code instead (incus: ayatori-*, etcd's lxc.yml:
# etcd-pve*); move a record there if its host later gains one.

# ayatori-* moved to infrastructure/incus/terraform, which imports them.
removed {
  from = powerdns_record.ayatori_dev_a
  lifecycle { destroy = false }
}

removed {
  from = powerdns_record.ayatori_prod_a
  lifecycle { destroy = false }
}

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

resource "powerdns_record" "sandbox_k8s_a" {
  zone    = powerdns_zone.lab.name
  name    = "sandbox-k8s.lab.ddupan.top."
  type    = "A"
  ttl     = 300
  records = ["10.60.0.13"]
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
