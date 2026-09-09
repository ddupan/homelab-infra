output "site_id" {
  value       = netbox_site.this.id
  description = "NetBox ID of the Homelab site."
}

output "prefix_ids" {
  value       = { for k, p in netbox_prefix.this : k => p.id }
  description = "prefix -> NetBox ID, for cross-referencing from other tooling."
}

output "device_ids" {
  value       = { for k, d in netbox_device.this : k => d.id }
  description = "device name -> NetBox ID."
}
