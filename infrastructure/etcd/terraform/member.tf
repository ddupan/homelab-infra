# Members renew their own certificates (homelab_data::etcd in homelab-cookbooks): each
# node logs in with its SPIFFE ID spiffe://ddupan.top/node/<member>/etcd (a SPIRE
# workload entry for root on that node, platform/spire/etcd-members.yaml) and may only
# sign the member certificate roles.
#
# Any member may sign for any member name: a Bao PKI role cannot tie the CN to the caller
# without one role per member.

resource "vault_policy" "etcd_member" {
  name   = "homelab-etcd-member"
  policy = <<-EOT
    %{for role in ["server", "peer", "gateway", "admin"]~}
    path "${var.pki_mount}/sign/homelab-etcd-${role}" { capabilities = ["update"] }
    %{endfor~}
    path "auth/token/revoke-self" { capabilities = ["update"] }
  EOT
}

resource "vault_jwt_auth_backend_role" "etcd_member" {
  backend         = "jwt-spire"
  role_name       = "homelab-etcd-member"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["openbao"]
  # A comma-separated value matches any one of them.
  bound_claims = {
    sub = join(",", [for name in var.member_names : "spiffe://ddupan.top/node/${name}/etcd"])
  }
  token_policies          = [vault_policy.etcd_member.name]
  token_no_default_policy = true
  token_ttl               = 600
  token_max_ttl           = 600
}
