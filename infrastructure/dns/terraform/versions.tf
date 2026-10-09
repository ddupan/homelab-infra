terraform {
  required_version = ">= 1.6"
  required_providers {
    # mmianl/ is the maintained fork; pan-net/powerdns has not released since 2022.
    powerdns = { source = "mmianl/powerdns", version = "~> 2.5" }
  }
}

# The API key comes from PDNS_API_KEY: .gitea/scripts/tf.py reads it from
# bao kv/k8s/powerdns (the one copy pdns, Poweradmin and external-dns also use).
# The API admits only internal networks (LAN, labnet, retronet, k3s pods) —
# see apps/blocky/pdns.d/zz-local.conf; the key is what guards writes.
provider "powerdns" {
  server_url = "http://192.168.10.127:8053"
}
