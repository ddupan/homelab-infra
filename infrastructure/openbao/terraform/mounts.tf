# Secrets engines. IMPORTED from the running instance (see imports.tf) — these
# were originally created by ../ansible (role openbao_bootstrap).
#
# NOT MANAGED HERE, DELIBERATELY:
#   * the PKI ROOT CA  (pki/root/generate)
#   * the SSH CA keypair (ssh-client-signer/config/ca)
# Both are root-of-trust material. A Terraform resource for them would treat any
# drift as "regenerate", which would silently invalidate every issued cert and
# every trusted SSH CA line on every host. They stay one-time Ansible bootstrap.

resource "vault_mount" "kv" {
  path    = "kv"
  type    = "kv"
  options = { version = "2" }
}

resource "vault_mount" "pki" {
  path                  = "pki"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10y — must exceed the root CA's own lifetime

  # Required by ACME: OpenBao strips response headers not listed here, and
  # clients fail at the "new nonce" step without them. This is the ONE
  # intentional change in the import plan.
  allowed_response_headers = ["Replay-Nonce", "Link", "Location"]
}

resource "vault_mount" "ssh_client_signer" {
  path = "ssh-client-signer"
  type = "ssh"
}
