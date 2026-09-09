# NEC IX — conditional DNS forwarding for `ad.ddupan.top`

Makes the LAN router (NEC IX, `192.168.10.1`) forward queries for the AD zone to the
Samba DC (`192.168.10.5`) while sending everything else to its normal upstream.

> NEC IX is IOS-*like* but not IOS. Domain-based forwarding is **not** a `domain`
> command — you define a `url-list` that matches the domain and bind it to a
> `proxy-dns server`. Config mode is `configure` (no `terminal`); enable is
> `proxy-dns ip enable`.

## Scope

Only for non-domain LAN devices that resolve via the router. Domain-joined machines
and the DC itself must use `192.168.10.5` directly as primary DNS — pointing an AD
member at the router breaks Kerberos/SRV autodiscovery.

No loop: the router forwards `ad.ddupan.top` → DC, and the DC's `smb.conf`
`dns forwarder = 192.168.10.1` sends non-AD queries back to the router. Different
zones, so they don't ping-pong.

## Config

```
enable
configure
!
! 1. match the AD zone (and its subdomains)
url-list AD-ZONE permit domain ad.ddupan.top
url-list AD-ZONE permit domain *.ad.ddupan.top
!
! (optional) reverse zone for 192.168.10.0/24
url-list AD-ZONE permit domain *.10.168.192.in-addr.arpa
!
! 2. enable proxy-dns (skip if already enabled)
proxy-dns ip enable
!
! 3. send AD-zone queries to the DC; higher priority = preferred/first
proxy-dns server 192.168.10.5 url-list AD-ZONE priority 200
!
!    keep your existing upstream server(s) as the catch-all at lower priority, e.g.
! proxy-dns server 192.168.10.1 priority 100        <- (your current default; leave as-is)
!
exit
write memory
```

How it resolves: a query is offered to the `proxy-dns server`s in priority order;
the DC (200) is bound to `AD-ZONE`, so it only takes queries matching the url-list.
Anything not matching falls through to your existing catch-all server(s) at lower
priority — so existing internet DNS keeps working unchanged.

Verify grammar on your unit — classic IX (IX2215-era IXOS) and newer IX-R/IX-V share
this shape, but use `?` to confirm. Notably:
- The `proxy-dns server` line accepts `[INTERFACE [NEXTHOP|dhcp]]` before `url-list`;
  the DC is on the local LAN so no interface/nexthop is needed.
- `url-list ... permit domain` patterns: `ad.ddupan.top` matches the apex,
  `*.ad.ddupan.top` matches hosts under it. Add both.
- Persist with `write memory`.

## Verify

From a non-domain LAN client using the router as resolver:

```bash
nslookup dc1.ad.ddupan.top 192.168.10.1                     # → 192.168.10.5
nslookup -type=srv _ldap._tcp.ad.ddupan.top 192.168.10.1    # → dc1 ...
nslookup example.com 192.168.10.1                           # still resolves normally
```

Reverse (only if the in-addr.arpa url-list entry was added):

```bash
nslookup 192.168.10.5 192.168.10.1                          # → dc1.ad.ddupan.top
```
