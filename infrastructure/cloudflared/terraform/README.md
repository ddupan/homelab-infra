# Cloudflare tunnel + DNS as code (Terraform)

The cloudflared tunnel runs **token-managed** (`TUNNEL_TOKEN` in the Deployment), so its
ingress config is authoritative **at Cloudflare's edge**, not the in-cluster `config.yml`
(which is ignored in token mode). This Terraform manages that edge config + DNS declaratively.

- `cloudflare_zero_trust_tunnel_cloudflared_config.main` — the tunnel's full ingress list
  (all public hostnames → in-cluster services). First match wins; `http_status:404` stays last.
- `cloudflare_dns_record.tunnel[<host>]` — one proxied CNAME `<host> → <tunnel>.cfargotunnel.com`
  per ingress hostname, derived from the same list.

> The `../cloudflared/cloudflared.yaml` `config.yml` ingress is now cosmetic. Either keep it
> in sync for documentation, or drop `TUNNEL_TOKEN` to make it authoritative instead — but
> we chose Terrraform-over-edge-config so the tunnel stays dashboard/token managed.

## One-time setup

1. **Create a Cloudflare API token** (dash → My Profile → API Tokens) with:
   - Account · **Cloudflare Tunnel : Edit**
   - Zone · **DNS : Edit** (zone `ddupan.top`)
   - Zone · **SSL and Certificates : Edit**（zone `ddupan.top`）— `cloudflare_origin_ca_certificate.gitea`（A1 源站证书）
   - Zone · **Config Rules : Edit**（zone `ddupan.top`）— `cloudflare_ruleset.config_settings`（git.ddupan.top 关 BIC）
   - Account · **Workers Scripts : Edit** — `go-vanity.tf`（go.ddupan.top 的 Go vanity import Worker 与其 custom domain）
2. Provide it + the zone id:
   ```bash
   export TF_VAR_cloudflare_api_token='...'
   # zone id:
   curl -s -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
     "https://api.cloudflare.com/client/v4/zones?name=ddupan.top" | jq -r '.result[0].id'
   export TF_VAR_zone_id='<that id>'
   ```
3. **Adopt existing resources into state** (they already exist — don't recreate):
   ```bash
   terraform init
   # tunnel config singleton:
   terraform import cloudflare_zero_trust_tunnel_cloudflared_config.main \
     65bf9ede92caa915f992fdf3d1e7b2f1/ff392451-b0b1-45bb-964e-6d9372c3a9e3
   # each existing hostname's DNS record (get its id from the API, then):
   terraform import 'cloudflare_dns_record.tunnel["<host>"]' $TF_VAR_zone_id/<record_id>
   ```

## Apply

```bash
terraform plan     # review: only the hostnames you changed should move
terraform apply
```

State is local (`terraform.tfstate`, gitignored). Move to a remote backend (r2/s3) if this
grows.
