# netboot

Self-hosted [netboot.xyz](https://netboot.xyz) PXE boot server for the LAN, using the
official appliance container plus a `dnsmasq` proxyDHCP so it coexists with the existing
DHCP server (the **NEC IX router**, which is left untouched).

## Architecture

The NEC IX router keeps leasing IPs. `dnsmasq` runs in **proxyDHCP** mode and only answers
the PXE/boot part of the conversation, pointing clients at this host (`192.168.10.127`).

Client type (announced via DHCP option 60/93) → what it gets:

| Client                                   | Transport | File                                         |
|------------------------------------------|-----------|----------------------------------------------|
| Legacy BIOS (`arch 0`)                   | TFTP      | `netboot.xyz.kpxe`                           |
| UEFI, normal PXE (`arch 7/9`)            | TFTP      | `netboot.xyz.efi`                            |
| UEFI with HTTP Boot (`vendor HTTPClient`)| HTTP      | `http://192.168.10.127:8080/menus/netboot.xyz.efi` |

Fallback is automatic: a UEFI box only announces `HTTPClient` when HTTP Boot is actually
enabled/supported; otherwise it does normal PXE and lands on the TFTP `.efi` branch.

This is a **two-stage** chain, which matters for the dnsmasq config:

1. **Firmware → netboot.xyz iPXE.** Raw firmware (not iPXE) gets the binary above. proxyDHCP
   *requires* `pxe-service` here — plain `dhcp-boot` produces no boot offer in proxy mode.
2. **netboot.xyz iPXE → menu.** The loaded `.efi`/`.kpxe` re-does DHCP (announcing itself via
   option 175) and dnsmasq answers with `dhcp-boot=tag:ipxe,netboot.xyz.efi,,192.168.10.127`.
   Two details matter, both dictated by the bootstrap **embedded in the netboot.xyz binary**:

   - **The bootfile must be a *recognised binary name*** (`netboot.xyz.efi`), not `menu.ipxe`.
     The embedded bootstrap only chains the menu **locally** (its `:tftpmenu` branch) when the
     bootfile matches one of its own binary names; any other name skips that branch and boots
     the **public** `boot.netboot.xyz` menu instead.
   - **The router's DHCP `next-server` must point at `192.168.10.127`** (see below). Under
     proxyDHCP the bootstrap fetches its `local-vars.ipxe` from `${next-server}` — the value
     from the *real* DHCP server (the NEC IX router), **not** from dnsmasq's
     `${proxydhcp/next-server}`. `local-vars.ipxe` is what sets `use_proxydhcp_settings true`
     (the no-keypress switch), so if it can't be fetched the UEFI client stalls fetching from
     the router, then prompts for a `p` keypress or falls back to the public menu.

The boot binaries then chain the menu **locally** over TFTP from `192.168.10.127`, so clients
boot *this* host's menu, not the public site. Only the version check and distro mirrors reach
the internet.

### Required NEC IX router setting

The router keeps leasing IPs as before, but its DHCP scope for the LAN must advertise
**`next-server 192.168.10.127`** (a.k.a. the `siaddr` / BOOTP server field) on the LAN DHCP
pool. This is the one piece of PXE config the router *does* need — it does not otherwise
PXE-boot anything, and regular (non-PXE) DHCP clients ignore `next-server`. Set it via the
DHCP-server/boot-server (`siaddr`) option of the IX DHCP profile serving the `192.168.10.0/24`
scope; leave the bootfile name unset (dnsmasq's proxyDHCP still supplies it).

## Services (all on host `192.168.10.127`)

| Port        | Service   | Provided by            | Purpose                                  |
|-------------|-----------|------------------------|------------------------------------------|
| `67/udp`    | proxyDHCP | `dnsmasq` (host net)   | PXE boot offers (no IP leasing)          |
| `69/udp`    | TFTP      | `netbootxyz`           | serves `/config/menus` (binaries + menu) |
| `8080`      | HTTP      | `netbootxyz` nginx     | `/` = `/assets` mirror; `/menus/` = binaries (UEFI HTTP Boot) |
| `3000`      | Web UI    | `netbootxyz`           | manage menus / download assets           |

## Usage

```bash
docker compose up -d        # start
docker compose logs -f dnsmasq   # watch DHCP offers during a client boot
docker compose down         # stop
```

Config manager (add/update distros, edit menus): <http://192.168.10.127:3000>

## Verified

Both PXE paths were tested end-to-end with QEMU VMs bridged onto `br0` (real SeaBIOS and
OVMF/UEFI firmware), booting all the way to the local netboot.xyz menu:

- **Legacy BIOS** → proxyDHCP offered `netboot.xyz.kpxe` → TFTP → local menu rendered ✅
- **UEFI x64** → proxyDHCP offered `netboot.xyz.efi` → TFTP → local menu rendered ✅
- **UEFI HTTP Boot** → configured, not yet VM-tested (hard to trigger in QEMU).

To re-test: create a tap on `br0`, run a diskless QEMU VM with `-boot n`, and watch
`docker compose logs -f dnsmasq` + `docker logs -f netbootxyz`.

## Notes / gotchas

- **Host networking is required** for `netbootxyz`: TFTP renegotiates to an ephemeral
  port that Docker's bridge NAT mangles (clients get `TID mismatch`). Host net serves TFTP
  straight off the LAN interface.
- `NGINX_PORT` is ignored by the image; the nginx listen port is pinned to `8080` in
  `config/nginx/site-confs/default`, which also adds a `/menus/` location so UEFI HTTP Boot
  can fetch the first-stage `.efi`. (If the appliance ever regenerates that file on upgrade,
  re-add the `listen 8080` and `/menus/` bits.)
- `dnsmasq` binds **only `br0`** (`interface=br0` + `bind-interfaces`) so it doesn't clash
  with libvirt's own dnsmasq on `virbr0`/`virbr1`.
- `config/menus/local-vars.ipxe` sets `use_proxydhcp_settings true` so proxyDHCP clients
  boot without a keypress prompt.
- The NEC IX router needs **no PXE configuration** — proxyDHCP handles everything.
- Editing `dnsmasq.conf` requires `docker restart netboot-dnsmasq` (compose won't
  auto-recreate on a bind-mounted file content change).

## Files

- `compose.yaml` — the two services (`netbootxyz` + `dnsmasq`)
- `dnsmasq.conf` — proxyDHCP + arch detection
- `config/` — netbootxyz appliance state (menus, nginx conf); managed by the container
- `assets/` — optional locally-mirrored distro images
- `buildout/` — leftover from an earlier manual build; **no longer used** (safe to delete)
