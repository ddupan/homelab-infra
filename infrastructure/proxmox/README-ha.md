# Proxmox HA — and the watchdog that makes it real

HA was enabled for **one** guest on 2026-07-26. The cluster's posture is otherwise
unchanged: no HA, guests disposable.

| | |
|---|---|
| resource | `vm:100` (`vyos-rtr`), `state started`, `max_restart 3`, `max_relocate 2` |
| why | it is the gateway for **both** SDN VNets and an OSPF speaker; losing it takes `labnet` + `retronet` offline (the main LAN is unaffected — the NEC IX is its gateway) |
| storage | `pve-rg` (DRBD, place-count 2): `pve1` + `pve2` hold **UpToDate diskful** replicas, `pve3` attaches **diskless** — so it can start on any node |
| codified | `ansible/roles/pve_ha` + `ansible/ha.yml` (separate from `site.yml`, like `cluster.yml`) |

**What this buys, precisely:** crash *restart* on another node, roughly **1–3 minutes**
of gateway downtime. It is **not** seamless failover. Real gateway HA is a second VyOS
with VRRP owning `10.60.0.1`/`10.61.0.1`; that was considered and deferred.

**What it costs:** adding any HA resource **arms fencing cluster-wide**. A node that
loses quorum now self-reboots. Corosync here runs a **single ring** on the flat 1G LAN,
so a network blip is now a reboot rather than a shrug.

Also set at the same time: `qm set 100 --agent 0`. PVE had `agent: enabled=1` while
VyOS 2025.11 ships **no `qemu-ga` binary and no apt sources** — the virtio channel was
wired but nothing could answer, so snapshots could not filesystem-freeze and no guest
IPs were reported. Installing it would mean adding Debian repos to the only router, and
would be wiped by the next `add system image`.

## ⚠ The watchdog is still `softdog` — finish this

`softdog` is a **software** watchdog: a kernel timer. **It cannot fire when the kernel
itself is frozen**, which is exactly the failure this cluster has actually had (pve2's
Raven Ridge idle freeze). So today's HA covers clean crashes, power loss and network
partition — but *not* the freeze case that motivated it.

Hardware watchdogs are present and verified (2026-07-26):

| node | module | timeout |
|---|---|---|
| pve1 (Intel i3-6100U) | `iTCO_wdt` | 30s |
| pve2 / pve3 (Ryzen 2400GE) | `sp5100_tco` | 60s |

`ansible/ha.yml` already writes the config (`WATCHDOG_MODULE` + a `blacklist softdog`
in `/etc/modprobe.d/pve-ha-watchdog.conf`). **Both are needed**: `watchdog-mux` opens
`/dev/watchdog`, which belongs to whichever watchdog registered *first*, and PVE loads
softdog at boot — so setting `WATCHDOG_MODULE` alone leaves the hardware module sitting
unused as `watchdog1`.

It takes effect on **the next reboot of each node**. The play deliberately does not
reboot: a surprise rolling reboot of all three nodes is not something an idempotent
baseline run should do.

### Live swap, without rebooting (do it in this order)

The danger is stopping `watchdog-mux` while an LRM holds the watchdog — that self-fences
the node. Parking the resource first removes every active LRM, which makes the rest safe.

```bash
# 1. park the resource; all LRMs go idle and release their watchdogs
ha-manager set vm:100 --state ignored
# wait until NO line says "watchdog active" — vm:100 keeps running throughout
ha-manager status

# 2. per node (pve3, pve2, pve1 — least critical first):
systemctl stop watchdog-mux
rmmod softdog
modprobe -r iTCO_wdt 2>/dev/null; modprobe iTCO_wdt      # pve1
# modprobe -r sp5100_tco; modprobe sp5100_tco            # pve2 / pve3
cat /sys/class/watchdog/watchdog0/identity                # must be the HW one now
systemctl start watchdog-mux                              # Restart=no: start it explicitly
ls -l /proc/$(pidof watchdog-mux)/fd | grep watchdog      # must hold /dev/watchdog

# 3. hand the resource back
ha-manager set vm:100 --state started
ha-manager status
```

If a step fails, leave `vm:100` in `ignored` and fix it — the VM keeps running and
nothing gets fenced. `ignored` means HA does not touch the guest, not that it stops.

## Verify

```bash
ha-manager status                    # "fencing armed", "service vm:100 (pveN, started)"
ha-manager config
qm config 100 | grep -E 'agent|onboot'
linstor r l | grep pm-                # replica placement
```

## Undo

```bash
ha-manager remove vm:100             # disarms fencing once no resources remain
rm /etc/modprobe.d/pve-ha-watchdog.conf
# and revert WATCHDOG_MODULE in /etc/default/pve-ha-manager
```
