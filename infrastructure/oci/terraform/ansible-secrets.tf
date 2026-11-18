# Secrets for the oci-arm Ansible roles (gitea, outside_watcher), read on the instance itself via
# instance principal. They replace host_vars/oci_arm/vault.yml: that file shared its password with
# every other ansible-vault in the repo, so whoever could deploy oci-arm (e.g. CI) could also decrypt
# Bao's own secrets. Not in Bao on purpose: Gitea and the watcher must be rebuildable with the lab down
# (infrastructure/oci/ansible/README.md), and this vault is already the out-of-lab recovery store.
#
# Terraform owns the secret objects, not their values: it creates them with a placeholder and ignores
# content afterwards, so values never pass through state or CI. Write a value with
#   oci vault secret update-base64 --secret-id <id> --secret-content-content <base64 JSON>
# where the JSON keys are the Ansible variable names (see infrastructure/oci/ansible/README.md).
locals {
  ansible_secrets = {
    "ansible-gitea"           = "Gitea app keys, origin TLS key, SMTP, Entra client secret, signing key"
    "ansible-outside-watcher" = "Telegram bot token of the outside watcher"
  }
}

resource "oci_vault_secret" "ansible" {
  for_each       = local.ansible_secrets
  compartment_id = var.compartment_ocid
  vault_id       = oci_kms_vault.recovery.id
  key_id         = oci_kms_key.recovery.id
  secret_name    = each.key
  description    = "${each.value} — read by oci-arm (roles/oci_secrets)"

  secret_content {
    content_type = "BASE64"
    content      = base64encode("{}")
  }

  lifecycle {
    ignore_changes = [secret_content]
  }
}

# Its own group rather than gitea_backup's: that one is named for and scoped to the backup bucket.
resource "oci_identity_dynamic_group" "oci_arm_secrets" {
  compartment_id = var.compartment_ocid
  name           = "homelab-vm-ansible-secrets"
  description    = "oci-arm (homelab-vm) reading its Ansible secrets"
  matching_rule  = "instance.id = '${oci_core_instance.vm.id}'"
}

resource "oci_identity_policy" "oci_arm_secrets" {
  compartment_id = var.compartment_ocid
  name           = "homelab-vm-ansible-secrets"
  description    = "oci-arm reads only its own Ansible secrets, not the other recovery secrets in the vault"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.oci_arm_secrets.name} to read secret-bundles in tenancy where any {${join(", ", [for n in keys(local.ansible_secrets) : "target.secret.name = '${n}'"])}}",
  ]
}

output "ansible_secrets_vault_id" {
  value = oci_kms_vault.recovery.id
}

output "ansible_secret_ids" {
  value = { for k, s in oci_vault_secret.ansible : k => s.id }
}
