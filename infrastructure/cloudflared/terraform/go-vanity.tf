# go.ddupan.top: vanity import paths for our Go modules, so the module path does not name the
# forge. Moving a repository again means changing one URL here, not every import. The module
# proxies (proxy.golang.org, Artifact Keeper) cache published versions, so an outage of this
# Worker only blocks the first fetch of a new version.
# Token scopes this adds: Account · Workers Scripts:Edit (script + custom domain); the custom
# domain also writes its DNS record and certificate in the zone.
locals {
  go_modules = {
    ayatori = "https://github.com/ddupan/ayatori"
  }
}

resource "cloudflare_workers_script" "go_vanity" {
  account_id         = var.account_id
  script_name        = "go-vanity"
  content            = file("${path.module}/go-vanity.js")
  main_module        = "go-vanity.js"
  compatibility_date = "2026-11-01"
  bindings = [{
    type = "json"
    name = "MODULES"
    json = jsonencode(local.go_modules)
  }]
}

resource "cloudflare_workers_custom_domain" "go_vanity" {
  account_id = var.account_id
  zone_id    = var.zone_id
  hostname   = "go.${var.zone_name}"
  service    = cloudflare_workers_script.go_vanity.script_name
}
