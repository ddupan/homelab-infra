# external-dns

Writes HTTPRoute hostnames under `lab.ddupan.top` into PowerDNS
(`../../apps/blocky/`, `../../infrastructure/dns/`). Adding a LAN service is then
one HTTPRoute attached to the Gateway's `https-lab` listener; the A record
(→ the Gateway address, 192.168.10.127) appears within a minute.

- **Ownership.** Each record it creates gets a TXT marker (owner `k3s-homelab`).
  With `policy: sync` it deletes its own records when the route goes away, and
  never touches records without its marker — the fixed hosts from Terraform and
  anything added in Poweradmin. A route whose hostname is already a Terraform
  name is skipped (logged), not taken over.
- **Scope.** `domainFilters: [lab.ddupan.top]`. It cannot write `ad.ddupan.top`
  (Samba) or public `ddupan.top` (Cloudflare) — routes on those listeners are
  ignored.
- **Key.** `kv/k8s/powerdns` via ESO, the same single copy pdns uses.
- **No dry-run** for the pdns provider. To see what it would do, read its logs
  after a change; it reconciles every minute.
