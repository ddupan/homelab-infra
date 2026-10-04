# Manages the REMOTE (dashboard) config of the token-managed cloudflared tunnel.
# This is what's actually authoritative when the pod runs with TUNNEL_TOKEN — the
# in-cluster config.yml ingress is ignored in that mode. Terraform is the source of truth.

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.account_id
  tunnel_id  = var.tunnel_id

  config = {
    # First match wins; the http_status:404 catch-all MUST stay last.
    ingress = [
      {
        hostname = "auth.ddupan.top"
        # Authelia's k8s Service listens on :80 (targetPort -> container 9091).
        # Hitting :9091 on the service yields 502; the service port is 80.
        service = "http://authelia.authelia.svc.cluster.local:80"
      },
      {
        # iam-login issuer. Straight to the Service like Authelia; Cloudflare's
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
        service = "http_status:404"
      },
    ]

    origin_request = {
      no_tls_verify = true
    }
  }
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
