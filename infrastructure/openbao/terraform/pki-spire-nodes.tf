# SPIRE 节点身份专用 CA。SPIRE Server 的 x509pop attestor 信任凡链到本根的证书，
# 证书 CN 即节点身份（node alias 的 selector），因此它必须是独立的根：挂在 pki/ 下的话，
# pki/ 签过的任何证书都能冒充一个节点、拿到该节点上所有 workload 的 SVID。
#
# 节点经 ACME 自行签发与续期（certbot http-01），EAB 只在首次注册账户时需要：
# Ansible enrollment play 用 laptop 身份铸一次性 EAB 交给节点，之后续期只靠账户密钥。
# 仅有 DNS 写权限、没有 EAB 的人无法注册账户，也就无法为节点名取得证书。
resource "vault_mount" "pki_spire_nodes" {
  path                  = "pki-spire-nodes"
  type                  = "pki"
  max_lease_ttl_seconds = 315360000 # 10y — 须覆盖根证书自身寿命

  # ACME 必需：OpenBao 会剥掉未列出的响应头，客户端在 new-nonce 一步失败。
  allowed_response_headers = ["Replay-Nonce", "Link", "Location"]
}

resource "vault_pki_secret_backend_root_cert" "spire_nodes" {
  backend     = vault_mount.pki_spire_nodes.path
  type        = "internal" # 私钥在 Bao 内生成，不可导出
  common_name = "ddupan homelab SPIRE node CA"
  ttl         = "315360000"
  key_type    = "ec"
  key_bits    = 256

  lifecycle {
    # 换根 = SPIRE Server 的 x509pop CA bundle 要换、所有节点证书要重签；只能有意为之。
    prevent_destroy = true
  }
}

resource "vault_pki_secret_backend_role" "spire_node" {
  backend = vault_mount.pki_spire_nodes.path
  name    = "node"

  # 节点以 lab.ddupan.top 下的 DNS 名注册（infrastructure/dns/README.md）。
  allowed_domains    = ["lab.ddupan.top"]
  allow_subdomains   = true
  allow_bare_domains = false
  allow_glob_domains = false
  allow_any_name     = false
  allow_ip_sans      = false
  server_flag        = false
  # 只用于向 SPIRE Server 证明节点。注意 OpenBao ACME 签出的证书 EKU 实为 serverAuth
  # （2026-10-09 实测，不随此标志）；SPIRE x509pop 以 ExtKeyUsageAny 校验，不受影响。
  client_flag         = true
  key_type            = "ec"
  key_bits            = 256
  use_csr_common_name = true
  # certbot 在剩 30 天时续期；60d 留 30 天重试窗口（WAN 不稳），低于 ACME 90d 上限。
  ttl     = 5184000 # 60d
  max_ttl = 7776000 # 90d
}

# ACME order/directory URLs and every issued cert's AIA are built from this, so it is
# what nodes actually call. lab directly, not var.bao_address (still ad while the rest
# of bao migrates): this mount is new, and starting on lab avoids moving it later.
locals {
  spire_nodes_bao = "https://bao.lab.ddupan.top:8200"
}

resource "vault_pki_secret_backend_config_cluster" "spire_nodes" {
  backend  = vault_mount.pki_spire_nodes.path
  path     = "${local.spire_nodes_bao}/v1/${vault_mount.pki_spire_nodes.path}"
  aia_path = "${local.spire_nodes_bao}/v1/${vault_mount.pki_spire_nodes.path}"
}

resource "vault_pki_secret_backend_config_acme" "spire_nodes" {
  backend = vault_mount.pki_spire_nodes.path
  enabled = true

  # 只开放角色目录 roles/node/acme/directory；默认目录禁用，EAB 也绑定在角色目录上。
  default_directory_policy = "forbid"
  allowed_roles            = [vault_pki_secret_backend_role.spire_node.name]
  allowed_issuers          = ["*"]

  # EAB 只在注册新账户时需要；续期用已注册的账户密钥，节点上不留长期秘密。
  eab_policy = "new-account-required"

  # Bao 自己的解析器解析 lab 名（经 DC → Blocky → PowerDNS），http-01 回连节点 :80
  # （2026-10-09 实测从 Bao VM 访问 etcd-pve1.lab.ddupan.top:80 成功）。
  dns_resolver = ""

  depends_on = [vault_pki_secret_backend_config_cluster.spire_nodes]
}
