terraform {
  required_version = ">= 1.5"
  required_providers {
    netbox = {
      source = "e-breuninger/netbox"
      # ⚠ Pin to 5.x. Provider 4.3.1 FAILS against NetBox 4.6 at provider-configure time
      # with a go-openapi error ("... is not supported by the TextConsumer"); 5.7.0 works.
      version = "~> 5.0"
    }
  }
}

# Same pattern as ../../../infrastructure/openbao/terraform and ../../../infrastructure/cloudflared/terraform: credentials come
# from outside the repo, state is local and gitignored.
provider "netbox" {
  # ⚠ BASE URL ONLY — no /api suffix. Passing ".../api" produces the same misleading
  # TextConsumer error as the version mismatch above and costs an hour to diagnose.
  server_url = var.netbox_url
  api_token  = var.netbox_token
  # refresh 默认 10 路并发打到单个 NetBox Pod，个别请求会超过 provider 默认超时
  # （CI plan 2026-10-04 报 "context deadline exceeded"）。放宽超时而不是降并发。
  request_timeout = 60
}
