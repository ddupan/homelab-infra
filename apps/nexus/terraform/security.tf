resource "sonatyperepo_privilege_repository_view" "anonymous_ansible" {
  name        = "ci-anonymous-ansible-read"
  description = "Anonymous read access to the Ansible Galaxy group"
  actions     = ["BROWSE", "READ"]
  format      = "ansiblegalaxy"
  repository  = sonatyperepo_repository_ansiblegalaxy_group.public.name
}

resource "sonatyperepo_privilege_repository_view" "anonymous_ansible_proxy" {
  name        = "ci-anonymous-ansible-proxy-read"
  description = "Anonymous artifact read access to the Ansible Galaxy proxy"
  actions     = ["BROWSE", "READ"]
  format      = "ansiblegalaxy"
  repository  = sonatyperepo_repository_ansiblegalaxy_proxy.galaxy.name
}

resource "sonatyperepo_privilege_repository_view" "anonymous_go" {
  name        = "ci-anonymous-go-read"
  description = "Anonymous read access to the Go module group"
  actions     = ["BROWSE", "READ"]
  format      = "go"
  repository  = sonatyperepo_repository_go_group.public.name
}

resource "sonatyperepo_privilege_repository_view" "anonymous_oci_public" {
  name        = "ci-anonymous-oci-public-read"
  description = "Anonymous read access to the public OCI group"
  actions     = ["BROWSE", "READ"]
  format      = "oci"
  repository  = "oci-public"
}

resource "sonatyperepo_privilege_repository_view" "anonymous_oci_proxy" {
  name        = "ci-anonymous-oci-proxy-read"
  description = "Anonymous read access to the OCI proxy member"
  actions     = ["BROWSE", "READ"]
  format      = "oci"
  repository  = "oci-proxy"
}

resource "sonatyperepo_role" "anonymous_ci" {
  id          = "ci-anonymous-read"
  name        = "CI anonymous read"
  description = "Read-only access to public CI dependency proxy groups"
  privileges = [
    sonatyperepo_privilege_repository_view.anonymous_ansible.name,
    sonatyperepo_privilege_repository_view.anonymous_ansible_proxy.name,
    sonatyperepo_privilege_repository_view.anonymous_go.name,
    sonatyperepo_privilege_repository_view.anonymous_oci_public.name,
    sonatyperepo_privilege_repository_view.anonymous_oci_proxy.name,
  ]
  roles = []
}

resource "sonatyperepo_user" "anonymous" {
  user_id       = "anonymous"
  first_name    = "Anonymous"
  last_name     = "User"
  email_address = "anonymous@example.org"
  status        = "active"
  roles         = [sonatyperepo_role.anonymous_ci.id]
}

resource "sonatyperepo_system_anonymous_access" "ci" {
  enabled    = true
  user_id    = sonatyperepo_user.anonymous.user_id
  realm_name = "NexusAuthorizingRealm"
}

resource "sonatyperepo_security_realms" "active" {
  active = [
    "NexusAuthenticatingRealm",
    "OciBearerToken",
  ]
}
