# Homepage

Start page with links to every app: <https://home.lab.ddupan.top> (LAN/Tailscale, no login —
it is only links, each app authenticates on its own).
[gethomepage/homepage](https://gethomepage.dev), plain manifests, Flux (`clusters/homelab/apps/homepage.yaml`).

## Where a tile comes from

- **Anything behind Envoy Gateway: annotate its HTTPRoute**, so the tile lives and dies with the
  route. Copy from `../poweradmin/httproute.yaml`:
  `enabled`, `name`, `group` (`应用` / `平台` / `基础设施`), `icon`, `description`, `href`.
  - Always set `href`. The fallback is `hostnames[0]` + `rules[0].matches[0]`, i.e. the old
    `ad` name on most routes, and a crash on routes without `matches` (grafana).
  - The status badge looks up pods by `app.kubernetes.io/name=<route name>`. When that is
    wrong, set `app` or `pod-selector` (see the iam-login, grafana and seaweedfs routes).
- **Everything else** (off-cluster hosts, routes rendered by a Helm chart): `config/services.yaml`.

Discovered tiles are listed before `services.yaml` ones within a group; `settings.yaml` only
fixes the group order. Discovery is read-only cluster-wide RBAC (`rbac.yaml`).

Icons: [dashboard-icons](https://github.com/homarr-labs/dashboard-icons) names (`gitea.svg`)
or Material Design (`mdi-*`).
