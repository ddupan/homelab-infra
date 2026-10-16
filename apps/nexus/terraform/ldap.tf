# AD login. Nexus CE has no OIDC, so platform administrators sign in over LDAP;
# the local admin stays for Terraform and as break-glass.

# The DC's LDAPS certificate is issued by the internal CA, which the JVM does not
# trust. One PEM for the whole lab, referenced rather than copied.
resource "sonatyperepo_security_ssl_truststore" "internal_ca" {
  # The provider rejects anything but a single trailing newline.
  pem = "${trimspace(file("${path.module}/../../../platform/trust-manager/bundle/internal-ca.pem"))}\n"
}

resource "sonatyperepo_system_config_ldap_connection" "ad" {
  name     = "ad"
  protocol = "LDAPS"
  hostname = var.ldap_hostname
  port     = 636
  # By hostname, verified against the internal CA.
  nexus_trust_store_enabled = true

  search_base   = var.ldap_search_base
  auth_scheme   = "SIMPLE"
  auth_username = var.ldap_bind_username
  auth_password = var.ldap_bind_password

  user_subtree              = true
  user_object_class         = "user"
  user_id_attribute         = "sAMAccountName"
  user_real_name_attribute  = "cn"
  user_email_name_attribute = "mail"
  # Only administrators may sign in: nobody else has anything to do in the UI, and
  # anonymous reads already cover CI.
  user_ldap_filter = "(memberOf=${var.ldap_admin_group_dn})"

  map_ldap_groups_to_roles = true
  group_type               = "DYNAMIC"
  user_member_of_attribute = "memberOf"

  depends_on = [sonatyperepo_security_ssl_truststore.internal_ca]
}

# An LDAP group maps to the Nexus role whose id is the group's CN.
resource "sonatyperepo_role" "platform_admins" {
  id          = var.ldap_admin_group
  name        = var.ldap_admin_group
  description = "AD ${var.ldap_admin_group}: Nexus administrators"
  roles       = ["nx-admin"]
}
