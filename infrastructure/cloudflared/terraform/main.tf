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
    {
      # Claude API trace export (Console → OpenTelemetry destination). The collector's
      # token-checked receiver (:4319), never the open in-cluster :4318. Anthropic appends
      # /v1/traces to the base URL and needs HTTPS on 443 — Cloudflare provides both.
      hostname = "otlp.ddupan.top"
      path     = "^/v1/traces$"
      service  = "http://otel-collector.monitoring.svc.cluster.local:4319"
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
