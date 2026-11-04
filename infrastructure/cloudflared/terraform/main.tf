# Manages the REMOTE (dashboard) config of the token-managed cloudflared tunnel.
# This is what's actually authoritative when the pod runs with TUNNEL_TOKEN — the
# in-cluster config.yml ingress is ignored in that mode. Terraform is the source of truth.

# One entry per public hostname. The tunnel route and its DNS record are both
# derived from this list, so a hostname cannot be routed without resolving, or
# resolve to the tunnel without a route.
locals {
  tunnel_ingress = [
    {
      # iam-login issuer. Straight to the Service; Cloudflare's
      # X-Forwarded-Proto is what tells the app the request was HTTPS.
      hostname = "sso.ddupan.top"
      service  = "http://iam-login.iam-login.svc.cluster.local:8080"
    },
    {
      hostname = "git.ddupan.top"
      service  = "http://gitea-http.gitea.svc.cluster.local:3000"
    },
    {
      hostname = "e5renew.ddupan.top"
      service  = "http://e5renew.e5renew.svc.cluster.local:80"
    },
    {
      hostname = "obj.ddupan.top"
      service  = "http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333"
    },
    {
      # Public copy of SPIRE's JWKS, for verifiers that fetch keys from the internet
      # (Anthropic WIF: explicit_url mode). Not the issuer — JWT-SVIDs still say
      # iss=https://spire-oidc.lab.ddupan.top; making THIS the issuer is a cutover
      # (platform/spire/README.md "Issuer migration"). Only the two public documents.
      hostname = "spire-oidc.ddupan.top"
      path     = "^/(\\.well-known/openid-configuration|keys)$"
      service  = "http://spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local:80"
    },
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    # First match wins; the http_status:404 catch-all MUST stay last.
    ingress = concat(local.tunnel_ingress, [{ service = "http_status:404" }])

    origin_request = {
      no_tls_verify = true
    }
  }
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = toset([for r in local.tunnel_ingress : r.hostname])
  zone_id  = var.zone_id
  name     = each.key
  type     = "CNAME"
  content  = "${var.tunnel_id}.cfargotunnel.com"
  proxied  = true
  ttl      = 1
}

# DKIM for Microsoft 365 mail sent as *@ddupan.top (via the smtp-relay). CNAMEs point
# at the tenant's DKIM keys; must be DNS-only (unproxied). Enable signing in Exchange
# after these resolve: smtp-relay/scripts/enable-dkim.ps1.
resource "cloudflare_dns_record" "dkim_selector1" {
  zone_id = var.zone_id
  name    = "selector1._domainkey.ddupan.top"
  type    = "CNAME"
  content = "selector1-ddupan-top._domainkey.ddupan1.d-v1.dkim.mail.microsoft"
  proxied = false
  ttl     = 3600
}

resource "cloudflare_dns_record" "dkim_selector2" {
  zone_id = var.zone_id
  name    = "selector2._domainkey.ddupan.top"
  type    = "CNAME"
  content = "selector2-ddupan-top._domainkey.ddupan1.d-v1.dkim.mail.microsoft"
  proxied = false
  ttl     = 3600
}

# 爬虫在边缘拦：2026-11-01 公网爬虫遍历 git.ddupan.top 的 pulls 全部排序×筛选×分页（1h 3600+
# 次、每次 3–4s 查询），把 laptop 上的 gitea 与 pg-prod 打满，所有 CI 跟着变慢。cloudflared 直连
# gitea-http，不经 Envoy，所以这是唯一能在 gitea 之前挡住它的地方。
# managed_challenge 而不是 block：人过一次挑战（cf_clearance）就照常浏览公开仓库；git clone/fetch
# （/info/refs、/git-upload-pack）和 /api 不在列表里，不受影响。内网与 CI 解析到 .127 走 Envoy，
# 根本不过 Cloudflare。路径与 gitea 的 isRoutePathExpensive 对齐；免费计划没有 matches，只能 contains。
resource "cloudflare_ruleset" "custom_firewall" {
  zone_id = var.zone_id
  name    = "default"
  kind    = "zone"
  phase   = "http_request_firewall_custom"

  rules = [{
    description = "gitea: challenge crawlers on expensive pages"
    action      = "managed_challenge"
    expression = join(" ", [
      "http.host eq \"git.ddupan.top\" and not starts_with(http.request.uri.path, \"/api/\") and (",
      join(" or ", [for p in [
        "/pulls", "/issues", "/src/", "/commits/", "/commit/", "/blame/", "/compare/", "/raw/",
        "/archive/", "/media/", "/graph", "/activity", "/wiki", "/rss/",
      ] : "http.request.uri.path contains \"${p}\""]),
      ")",
    ])
  }]
}
