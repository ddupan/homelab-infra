# Gitea（oci-arm）源站证书。git.ddupan.top 走 Cloudflare 代理直连 A1 公网 IP（不经 tunnel），
# CF 以 Full (strict) 校验源站，Origin CA 证书只被 CF 信任——lab 内客户端因此也必须经 CF 访问。
#
# 私钥不在这里生成：tls_private_key 会把私钥写进本 root 的 state（在 lab 的 S3 上）。
# 私钥只存在 infrastructure/oci/ansible/host_vars/oci_arm/vault.yml（vault_gitea_tls_key），
# 这里只提交公开的 CSR。轮换：重新生成私钥与 CSR，替换文件后 apply。
resource "cloudflare_origin_ca_certificate" "gitea" {
  csr                = file("${path.module}/gitea-origin.csr")
  hostnames          = ["git.ddupan.top"]
  request_type       = "origin-ecc"
  requested_validity = 5475
}

# 公开证书，apply 后写进 oci ansible 的 host_vars/oci_arm/gitea.yml（gitea_tls_cert）。
output "gitea_origin_certificate" {
  value = cloudflare_origin_ca_certificate.gitea.certificate
}

# git.ddupan.top 的 A 记录已移到 infrastructure/oci/terraform/dns.tf，跟实例公网 IP 一起维护。
# 这里只从 state 放手，不删除记录；两个 root 谁先 apply 都不影响。合并 apply 后可删掉这个块。
removed {
  from = cloudflare_dns_record.gitea
  lifecycle {
    destroy = false
  }
}

# 对 git.ddupan.top 关掉 Browser Integrity Check。BIC 按 User-Agent 拦"可疑"客户端，Python urllib 默认的
# `Python-urllib/3.x` 直接 403（error 1010）：CI 的 tf.py 往 PR 贴 plan 评论、chef converge.py、dns generate.py
# 等脚本都用它访问 Gitea API。切换前它们走 split-horizon 到 Envoy，不经 Cloudflare，所以这是切换后才暴露的。
# 这个主机名主要给机器用；防爬虫由 Gitea 自己的 REQUIRE_SIGNIN_VIEW = expensive 负责，不靠边缘猜 UA。
# token 需要 Zone · Config Rules : Edit（README）。
resource "cloudflare_ruleset" "config_settings" {
  zone_id = var.zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_config_settings"

  rules = [{
    description = "gitea: no browser integrity check (API/git clients)"
    expression  = "http.host eq \"git.ddupan.top\""
    action      = "set_config"
    action_parameters = {
      bic = false
    }
  }]
}
