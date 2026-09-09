# Blocky — LAN resolver, ad-blocker, split-horizon DNS

**Status: DEPLOYED and verified 2026-07-28. NOT yet the LAN resolver** — DHCP still
hands out the DC/router pair, so only clients querying 192.168.10.127 explicitly
use it. Flip DHCP to adopt it; `docker compose down` to abandon it.

Solves three things at once:

1. **Split-horizon.** `git.ddupan.top`, `auth.ddupan.top` and `obj.ddupan.top` are
   public names that resolve to Cloudflare. On the LAN they should resolve to the
   Envoy gateway so traffic never leaves the network to reach a service hosted on
   it. There is currently **nowhere** to put such a record: the DC is
   authoritative only for `ad.ddupan.top`, and the NEC IX has no static-host
   feature (`show dns` offers only `fqdn-database`).
2. **Ad-blocking**, which the DC cannot do.
3. **Query visibility.** There is none today. On 2026-07-28 a dead VPN tunnel was
   mis-diagnosed as a bad ISP for hours; a query log would have shortened that.

## Why here, and why compose

Only the laptop is always-on, so PVE is out despite being better isolated.

Within the laptop, this is a **compose stack rather than a k3s Deployment** on
purpose: DNS is the most foundational service on the network, and putting it
inside the cluster means a bad upgrade or a CrashLoop takes name resolution with
it. The cluster broke twice on 2026-07-28. Compose starts earlier in boot and has
fewer dependencies. k3s CoreDNS is untouched and keeps serving pods.

## Before deploying — the one step with no workaround

**The NEC IX is the DHCP server** (`netboot/dnsmasq.conf` is proxyDHCP only —
`dhcp-range=…,proxy` — so it assigns nothing). Clients get their resolver list
from the router, so pointing them at Blocky means changing the DHCP DNS option
there. Confirm that is editable before relying on any of this.

**Keep the router as a secondary resolver.** Today, if the laptop dies, clients
fall back to the router and the internet still works for the household. If Blocky
becomes the *only* resolver, a laptop reboot is a household-wide DNS outage.

The trade-off, stated plainly: clients that fall through to the secondary get
**no ad-blocking and no split-horizon** — they resolve `git.ddupan.top` to
Cloudflare and reach Gitea over the tunnel. That fails *open*, which is the right
direction for a household. Choose consistency over resilience only deliberately.

## Deploy

> Two bugs only surfaced on first run, both now fixed — see the notes at the
> bottom. Staging validated the syntax but could not have caught either.

```bash
mkdir -p logs
docker compose up -d
docker compose logs -f blocky        # expect "listening" + denylist counts
```

Verify **before** touching DHCP — nothing depends on it until then:

```bash
dig @192.168.10.127 git.ddupan.top   +short   # -> 192.168.10.127 (split-horizon)
dig @192.168.10.127 dc1.ad.ddupan.top +short  # -> 192.168.10.5   (conditional -> DC)
dig @192.168.10.127 github.com        +short  # -> real answer    (upstream)
dig @192.168.10.127 doubleclick.net   +short  # -> NXDOMAIN       (blocked)
curl -s http://192.168.10.127:4000/metrics | head
```

Only once all five behave should the DHCP option change.

## Rollback

Blocky holds no state that matters. Revert the DHCP DNS option and
`docker compose down`; clients return to the DC/router pair on next lease. Keep
the old option value written down before changing it.

## Notes

- **Upstream is the router (`192.168.10.1`), not DoH.** `cloudflare-dns.com` sits
  in `104.21/16` and `172.67/16` — precisely the ranges the NAIST VPN's
  split-tunnel routes swallow when the tunnel dies. A DoH upstream there would
  fail in the same silent way that cost hours on 2026-07-28.
- **AAAA is filtered for the custom names** (`filterUnmappedTypes` defaults true).
  Deliberate: the laptop's only global IPv6 belongs to `tun0`, so a AAAA answer
  would push LAN traffic into the VPN. Matches `../../platform/k3s/coredns-custom.yaml`.
- `../../platform/k3s/coredns-custom.yaml` still handles the same names for **pods**. The two
  are independent and must be kept in sync — a name added here usually wants
  adding there too.
- Metrics are scraped by `../../platform/observability/metrics/scrapes/blocky.yaml`.

## Bugs found on first deploy

Both were in the staged config and invisible to `docker compose config`, yamllint
and a server-side dry-run. Worth recording because the same shape recurs:

1. **`ports.dns: 192.168.10.127:53` in `config.yml`.** Those are the *container's*
   listen addresses, and that IP does not exist inside a bridge-networked
   container — Blocky exited with `cannot assign requested address`. Host-side
   restriction belongs in the compose `ports:` mapping; the container listens on
   all interfaces. Loud failure, quick fix.
2. **Query log silently did nothing.** The image runs as uid 100, `./logs` is
   created as uid 1000, so every query logged `fileQueryLogWriter: permission
   denied` while DNS itself worked perfectly. This is the dangerous one: the
   service looked healthy, answered correctly, and passed its healthcheck while
   the feature it was deployed for produced nothing. Fixed with `user: "1000:1000"`.

The second is the reason to check the *feature*, not just the process state.
