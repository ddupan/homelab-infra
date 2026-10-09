# lab.ddupan.top — the internal zone for hosts and services, served by PowerDNS
# behind Blocky (apps/blocky/). Samba keeps ad.ddupan.top for AD's own records.
#
# Several writers share this zone, each through the API:
#   this root     — the zone itself, plus hosts no code creates (hosts.tf)
#   owning roots  — records next to the thing they name (incus: ayatori-*)
#   external-dns  — HTTPRoute hostnames, marked by its TXT ownership records
#   Poweradmin    — ad-hoc records added by hand
# Terraform only touches the RRsets it declares, so the others are safe.

resource "powerdns_zone" "lab" {
  name = "lab.ddupan.top."
  kind = "Native"
  # Bump the SOA serial on every API change. Nothing transfers this zone yet;
  # a future pdns secondary (see apps/blocky/README.md) will rely on it.
  soa_edit_api = "DEFAULT"
}

resource "powerdns_record_soa" "lab" {
  zone  = powerdns_zone.lab.name
  name  = powerdns_zone.lab.name
  ttl   = 3600
  mname = "ns1.lab.ddupan.top."
  rname = "hostmaster.lab.ddupan.top."
  # The serial is pdns's job (soa_edit_api); leaving it unset avoids a diff on every apply.
  refresh = 10800
  retry   = 3600
  expire  = 604800
  # Negative-caching TTL. Short, because a name added via external-dns should
  # resolve within a minute even for a client that just asked and got NXDOMAIN.
  minimum = 60
}

# Internal-only zone: nothing delegates to it, clients reach it through Blocky's
# conditional forward. NS and ns1 exist because a zone without them is malformed.
resource "powerdns_record" "lab_ns" {
  zone    = powerdns_zone.lab.name
  name    = powerdns_zone.lab.name
  type    = "NS"
  ttl     = 3600
  records = ["ns1.lab.ddupan.top."]
}

resource "powerdns_record" "ns1" {
  zone    = powerdns_zone.lab.name
  name    = "ns1.lab.ddupan.top."
  type    = "A"
  ttl     = 3600
  records = ["192.168.10.127"]
}
