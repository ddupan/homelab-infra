# NetBox object graph, driven by topology.yml.
#
# WHY yamldecode rather than HCL resources per object: topology.yml stays the readable,
# authoritative artifact (git -> NetBox, see ../CONTEXT.md §4), and Terraform supplies what
# a plain script could not — state, `plan` as a drift report, and DELETION. Removing an
# entry from the YAML now removes the object from NetBox, which the previous seed script
# never did.
#
# Ownership boundary, matching ../../../infrastructure/openbao/terraform: Terraform owns API-level
# configuration. The k8s manifests that RUN NetBox live one level up in ../.

locals {
  topo = yamldecode(file("${path.module}/topology.yml"))

  # --- flattened lookup maps -------------------------------------------------
  # Interfaces are nested under devices/VMs in the YAML; Terraform needs flat maps keyed
  # by a stable string. "<parent>:<iface>" is that key everywhere below.
  device_ifaces = merge([
    for d in local.topo.devices : {
      for i in d.interfaces : "${d.name}:${i.name}" => merge(i, { device = d.name })
    }
  ]...)

  vm_ifaces = merge([
    for v in local.topo.virtual_machines : {
      for i in v.interfaces : "${v.name}:${i.name}" => merge(i, { vm = v.name })
    }
  ]...)

  # Only interfaces that actually carry an address.
  device_ips = { for k, i in local.device_ifaces : k => i if try(i.ip, null) != null }
  vm_ips     = { for k, i in local.vm_ifaces : k => i if try(i.ip, null) != null }

  # The single address that becomes the parent's primary_ip4.
  device_primary = { for k, i in local.device_ips : i.device => k if try(i.primary, false) }
  vm_primary     = { for k, i in local.vm_ips : i.vm => k if try(i.primary, false) }

  device_macs = { for k, i in local.device_ifaces : k => i if try(i.mac, null) != null }

  inventory_items = merge([
    for d in local.topo.devices : {
      for it in try(d.inventory_items, []) : "${d.name}:${it.name}" => merge(it, { device = d.name })
    }
  ]...)
}

# --- site + IPAM ---------------------------------------------------------------
resource "netbox_site" "this" {
  name        = local.topo.site.name
  slug        = local.topo.site.slug
  description = local.topo.site.description
  status      = "active"
}

resource "netbox_ipam_role" "this" {
  for_each = { for r in local.topo.prefix_roles : r.slug => r }
  name     = each.value.name
  slug     = each.value.slug
}

resource "netbox_vlan_group" "this" {
  name        = local.topo.vlan_group.name
  slug        = local.topo.vlan_group.slug
  description = local.topo.vlan_group.description
  # Required by the provider. The SDN zone is a plain VLAN zone on vmbr0, which is
  # bridge-vlan-aware for the full range, so do not narrow this without changing that.
  vid_ranges = [[1, 4094]]
}

resource "netbox_vlan" "this" {
  for_each = { for v in local.topo.vlans : tostring(v.vid) => v }
  vid      = each.value.vid
  name     = each.value.name
  group_id = netbox_vlan_group.this.id
  site_id  = netbox_site.this.id
  status   = "active"
}

resource "netbox_prefix" "this" {
  for_each = { for p in local.topo.prefixes : p.prefix => p }
  prefix   = each.value.prefix
  status   = "active"
  # The provider exposes plain `site_id` and handles NetBox 4.2+'s generic
  # scope_type/scope_id internally — which is exactly the trap that broke the hand-rolled
  # script (posting `site` was silently dropped). Using the provider avoids it.
  site_id     = netbox_site.this.id
  role_id     = netbox_ipam_role.this[each.value.role].id
  vlan_id     = try(netbox_vlan.this[tostring(each.value.vlan)].id, null)
  description = each.value.description
}

resource "netbox_ip_range" "this" {
  for_each      = { for r in local.topo.ip_ranges : "${r.start}-${r.end}" => r }
  start_address = each.value.start
  end_address   = each.value.end
  status        = each.value.status
  mark_utilized = try(each.value.mark_utilized, false)
  description   = each.value.description
}

# --- Wi-Fi ---------------------------------------------------------------------
# ⚠ PARTIAL: the provider can create the SSIDs but has NO attribute for attaching them to
# a radio interface, and none for `rf_role`. Neither does the netbox.netbox Ansible
# collection. That last mile is done by ./attach-wireless.py — see ../README.md.
resource "netbox_wireless_lan" "this" {
  for_each    = { for w in local.topo.wireless_lans : w.ssid => w }
  ssid        = each.value.ssid
  auth_type   = each.value.auth_type
  auth_cipher = each.value.auth_cipher
  description = each.value.description
  # auth_psk deliberately unset: OpenBao is the secrets store, not NetBox.
}

# --- hardware ------------------------------------------------------------------
resource "netbox_manufacturer" "this" {
  for_each = { for m in local.topo.manufacturers : m.slug => m }
  name     = each.value.name
  slug     = each.value.slug
}

resource "netbox_device_type" "this" {
  for_each        = { for d in local.topo.device_types : d.slug => d }
  model           = each.value.model
  slug            = each.value.slug
  manufacturer_id = netbox_manufacturer.this[each.value.manufacturer].id
  # Same reason as vm_role above: NetBox's default is true, so pin it or every plan wants
  # to clear it. Meaningless for this hardware (nothing is rack-mounted) but stops churn.
  is_full_depth = true
}

resource "netbox_device_role" "this" {
  for_each  = { for r in local.topo.device_roles : r.slug => r }
  name      = each.value.name
  slug      = each.value.slug
  color_hex = each.value.color
  # NetBox defaults this to true; the provider defaults it to false, so without pinning it
  # every plan shows a spurious vm_role true -> false diff.
  vm_role = true
}

resource "netbox_device" "this" {
  for_each       = { for d in local.topo.devices : d.name => d }
  name           = each.value.name
  site_id        = netbox_site.this.id
  role_id        = netbox_device_role.this[each.value.role].id
  device_type_id = netbox_device_type.this[each.value.type].id
  description    = each.value.description
  comments       = try(each.value.comments, "")
  serial         = try(each.value.serial, "")
  status         = try(each.value.status, "active")
}

resource "netbox_device_interface" "this" {
  for_each    = local.device_ifaces
  device_id   = netbox_device.this[each.value.device].id
  name        = each.value.name
  type        = each.value.type
  description = try(each.value.description, "")
  mtu         = try(each.value.mtu, null)
}

resource "netbox_inventory_item" "this" {
  for_each        = local.inventory_items
  device_id       = netbox_device.this[each.value.device].id
  name            = each.value.name
  manufacturer_id = netbox_manufacturer.this[each.value.manufacturer].id
  part_id         = try(each.value.part_id, "")
  serial          = try(each.value.serial, "")
  description     = try(each.value.description, "")
}

# MACs are first-class objects in NetBox 4.2+; `mac_address` on the interface is read-only.
resource "netbox_mac_address" "this" {
  for_each            = local.device_macs
  mac_address         = upper(each.value.mac)
  device_interface_id = netbox_device_interface.this[each.key].id
}

resource "netbox_device_interface_primary_mac_address" "this" {
  for_each       = local.device_macs
  interface_id   = netbox_device_interface.this[each.key].id
  mac_address_id = netbox_mac_address.this[each.key].id
}

# --- virtualization ------------------------------------------------------------
resource "netbox_cluster_type" "this" {
  for_each = { for c in local.topo.cluster_types : c.slug => c }
  name     = each.value.name
  slug     = each.value.slug
}

resource "netbox_cluster" "this" {
  for_each        = { for c in local.topo.clusters : c.name => c }
  name            = each.value.name
  cluster_type_id = netbox_cluster_type.this[each.value.type].id
  description     = each.value.description
  site_id         = netbox_site.this.id
}

resource "netbox_virtual_machine" "this" {
  for_each    = { for v in local.topo.virtual_machines : v.name => v }
  name        = each.value.name
  cluster_id  = netbox_cluster.this[each.value.cluster].id
  description = each.value.description
  # NetBox DERIVES a VM's site from its cluster. Leaving this unset makes the provider
  # try to clear it on every plan (site_id 1 -> None), so declare it to match.
  site_id = netbox_site.this.id
}

resource "netbox_interface" "this" {
  for_each           = local.vm_ifaces
  virtual_machine_id = netbox_virtual_machine.this[each.value.vm].id
  name               = each.value.name
  description        = try(each.value.description, "")
}

# --- addresses -----------------------------------------------------------------
resource "netbox_ip_address" "device" {
  for_each   = local.device_ips
  ip_address = each.value.ip
  status     = "active"
  # No `object_type` here: the provider pairs that with the GENERIC `interface_id`
  # ("all of interface_id,object_type must be specified"). The dedicated
  # *_interface_id attributes are standalone and imply the type.
  device_interface_id = netbox_device_interface.this[each.key].id
  # Native NetBox field. Setting it is INTENT: "this host needs a static A record in AD
  # DNS". Domain-joined hosts self-register and are deliberately absent.
  # ../generate/samba-a-records.py turns these into samba_ad_extra_a_records.
  dns_name = try(each.value.dns_name, "")
}

resource "netbox_ip_address" "vm" {
  for_each                     = local.vm_ips
  ip_address                   = each.value.ip
  status                       = "active"
  virtual_machine_interface_id = netbox_interface.this[each.key].id
  dns_name                     = try(each.value.dns_name, "")
}

# primary_ip4 lives on the parent, so the provider models it as its own resource.
resource "netbox_device_primary_ip" "this" {
  for_each      = local.device_primary
  device_id     = netbox_device.this[each.key].id
  ip_address_id = netbox_ip_address.device[each.value].id
}
