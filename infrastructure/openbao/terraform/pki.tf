# ── issuing role ──────────────────────────────────────────────────────────
# Caps what ACME (and direct issuance) may mint. dc1's LDAPS cert comes from here.
resource "vault_pki_secret_backend_role" "bao_server" {
  backend = vault_mount.pki.path
  name    = "bao-server"

  # lab.ddupan.top: services moving off the AD zone (infrastructure/dns/README.md).
  # ad stays: dc1's LDAPS and the PVE node certs are issued for ad names.
  allowed_domains    = ["ad.ddupan.top", "lab.ddupan.top"]
  allow_subdomains   = true
  allow_bare_domains = false
  allow_glob_domains = false
  allow_any_name     = false
  allow_ip_sans      = true # dc1's cert carries IP:192.168.10.5
  server_flag        = true
  client_flag        = true
  key_type           = "rsa"
  key_bits           = 2048
  max_ttl            = 31536000 # 1y
  # 60d. NOT 0: ttl=0 falls back to the system default of 768h (32 days), which
  # is what dc1's cert was getting. That is fine for lego (samba_ad_acme renews at
  # 10 days left) but breaks Proxmox: PVE's renewal threshold is hardcoded at "30
  # days to expiry" (PVE/API2/ACME.pm), so a 32-day cert renews every ~2 days and
  # restarts pveproxy each time. 60d leaves PVE a full 30-day retry window -- which
  # matters given the flaky WAN -- and stays well under OpenBao's 90d ACME cap.
  ttl                 = 5184000 # 60d
  use_csr_common_name = true
}

# ── cluster paths ─────────────────────────────────────────────────────────
# ACME directory/order URLs are built from these and embedded in issued certs as
# AIA URLs, so they must be reachable by clients exactly as written. Uses the
# public hostname (real Let's Encrypt cert via the openbao_acme Ansible role),
# not the bare IP.
resource "vault_pki_secret_backend_config_cluster" "this" {
  backend  = vault_mount.pki.path
  path     = "${var.bao_address}/v1/${vault_mount.pki.path}"
  aia_path = "${var.bao_address}/v1/${vault_mount.pki.path}"
}

# ── ACME ──────────────────────────────────────────────────────────────────
# WHY: dc1's LDAPS cert was hand-issued 2026-07-25 and expires 2027-07-25 with
# nothing to renew it. If it lapses, Authelia loses its LDAPS backend and every
# SSO consumer fails at once. ACME takes the human out of that loop.
resource "vault_pki_secret_backend_config_acme" "this" {
  backend = vault_mount.pki.path
  enabled = var.acme_enabled

  # SECURITY: OpenBao's default is "sign-verbatim" — it would issue ANY name a
  # client asks for, meaning anything able to reach bao could mint a cert for
  # dc1.ad.ddupan.top from the ROOT CA. Pinning to the role caps issuance at
  # that role's allowed_domains.
  default_directory_policy = "role:${vault_pki_secret_backend_role.bao_server.name}"
  allowed_roles            = [vault_pki_secret_backend_role.bao_server.name]
  allowed_issuers          = ["*"]

  # See variables.tf for the not-required vs EAB trade-off.
  eab_policy = var.acme_eab_policy

  # Empty = server's own resolver. bao resolves ad.ddupan.top correctly
  # (verified), so http-01 validation against internal hosts works.
  dns_resolver = ""

  depends_on = [vault_pki_secret_backend_config_cluster.this]
}

# ── issuing / CRL URLs ────────────────────────────────────────────────────
# Embedded in every issued cert so clients can fetch the CA and check the CRL.
# Previously set by ../ansible (pki.yml, "Configure issuing/CRL URLs") — moved
# here as part of the Terraform-owns-configuration split.
resource "vault_pki_secret_backend_config_urls" "this" {
  backend = vault_mount.pki.path

  issuing_certificates    = ["${var.bao_address}/v1/${vault_mount.pki.path}/ca"]
  crl_distribution_points = ["${var.bao_address}/v1/${vault_mount.pki.path}/crl"]
}
