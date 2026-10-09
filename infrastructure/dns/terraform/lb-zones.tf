# Zones for Ayatori's load balancer API, one per instance. Ayatori writes the
# records inside them through the pdns API; this root owns only each zone, its
# SOA and NS, and the delegation from lab.ddupan.top.
#
# A child zone of its own (not names inside lab.ddupan.top) keeps Ayatori's
# writes out of the zone that Terraform, external-dns and Poweradmin share, and
# lets either side be rebuilt without touching the other.
locals {
  lb_zones = {
    prod = "lb.lab.ddupan.top."
    dev  = "dev-lb.lab.ddupan.top."
  }
}

resource "powerdns_zone" "lb" {
  for_each     = local.lb_zones
  name         = each.value
  kind         = "Native"
  soa_edit_api = "DEFAULT"
}

resource "powerdns_record_soa" "lb" {
  for_each = powerdns_zone.lb
  zone     = each.value.name
  name     = each.value.name
  ttl      = 3600
  mname    = "ns1.lab.ddupan.top."
  rname    = "hostmaster.lab.ddupan.top."
  refresh  = 10800
  retry    = 3600
  expire   = 604800
  # Same reasoning as lab: a freshly registered LB name must resolve within a
  # minute even for a client that just cached NXDOMAIN.
  minimum = 60
}

resource "powerdns_record" "lb_ns" {
  for_each = powerdns_zone.lb
  zone     = each.value.name
  name     = each.value.name
  type     = "NS"
  ttl      = 3600
  records  = ["ns1.lab.ddupan.top."]
}

# Delegation in the parent. pdns already answers from the most specific zone it
# hosts, so this changes nothing for Blocky today; it makes the tree correct for
# any resolver that walks it (and for a future pdns secondary). No glue needed:
# ns1 sits in lab.ddupan.top itself, outside the delegated zones.
resource "powerdns_record" "lb_delegation" {
  for_each = powerdns_zone.lb
  zone     = powerdns_zone.lab.name
  name     = each.value.name
  type     = "NS"
  ttl      = 3600
  records  = ["ns1.lab.ddupan.top."]
}
