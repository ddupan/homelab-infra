# NetBox evaluation — handoff context

>  **STATUS 2026-07-26 — this brief has been ACTED ON. Read [`README.md`](README.md) first
>  for what actually exists.** NetBox is deployed at <https://netbox.ad.ddupan.top>, populated
>  from `terraform/topology.yml`, and two of the §4 consumers are proven by generators that
>  diff against live systems. This file is kept as the original brief and rationale; where
>  it disagrees with README.md, README.md is right.
>
>  Corrections found by measuring the hardware (`dmidecode`) rather than trusting §3:
>  pve1's CPU is an **i3-6100U** (not i3-6100) on board **NUC6i3SYB**, with **15 GiB**
>  usable; pve2/pve3 are Lenovo machine-type `10VGCTO1WW`. §3 also omitted **retrolab**
>  (10.60.0.10), which had a live AD DNS record all along.

Written 2026-07-25 for a fresh agent. Everything below is **verified live**, not assumed.
Nothing NetBox-related existed at the time of writing: this document is the brief, not a
record of work done.

---

## 1. Why this is being considered

The homelab is already managed as code (Ansible + Terraform, see §5). The gap NetBox would
fill is a **single source of truth for network facts**, which are currently duplicated across
three places that must be edited together and have no cross-check:

| fact | lives in | and again in | and again in |
|---|---|---|---|
| VNet `labnet` = VLAN 100 | `proxmox/ansible/roles/pve_sdn/defaults/main.yml` | — | — |
| subnet `10.60.0.0/24` | VyOS role `vyos_sdn_interfaces` | VyOS OSPF `area 0 network` | (implied by PVE VNet) |
| gateway `10.60.0.1` | VyOS role | — | — |
| host addresses (§3) | `proxmox/ansible/inventory/hosts.yml` | `samba-ad` DNS A records | router DHCP reservations |

Adding one VNet today means editing the PVE SDN role, the VyOS interface list, **and** the OSPF
network list. Forgetting the third is silent — the subnet exists and has a gateway, but nothing
outside can route to it.

**The user has NOT committed to adopting NetBox.** The task is to evaluate and propose, then
implement only if it earns its place. Be honest if it does not — for ~10 hosts and 2 VLANs it may
be more machinery than the duplication costs.

---

## 2. Physical / logical topology

```
            INTERNET (unstable — see §6)
                 │
        GigaEthernet0.0  10.1.72.0/24
        ┌────────┴─────────┐
        │   NEC IX router  │ 192.168.10.1
        │   (GigaEth2.0 =  │  · OSPF area 0  · BGP (17 routes via .127)
        │    LAN side)     │  · proxy-dns, DHCP pool .10–.250
        └────────┬─────────┘
                 │
        ┌────────┴──────────┐  UNMANAGED (dumb) switch
        │  flat L2 segment  │  · passes 802.1Q tags untouched (verified)
        │  192.168.10.0/24  │  · passes jumbo frames 9000 MTU (verified)
        └─┬──────┬────────┬─┘
          │      │        │
     pve1/2/3  laptop   (VMs)
```

- **Single flat 1G LAN, one dumb switch.** No managed switch, no second NIC per node.
- **MTU 9000** on the three PVE nodes' `vmbr0` + bridge port. Router/DC/laptop remain 1500;
  safe because TCP negotiates MSS in the SYN. Only large **UDP** to a 1500 host would break.
- **PVE SDN uses a VLAN zone**, not VXLAN — the dumb switch forwards tags, so VLAN is native and
  needs no encapsulation. VLANs here are **segmentation, not security**: nothing enforces them.

---

## 3. Address allocations (all verified reachable 2026-07-25)

### 192.168.10.0/24 — the LAN
| addr | host | notes |
|---|---|---|
| .1 | NEC IX router | gateway, OSPF, BGP, DNS proxy, DHCP server |
| .2 | `vyos-rtr` (VM 100) | VyOS 2025.11, SDN gateway + OSPF |
| .4 | `pve1` | Proxmox, LINSTOR **controller**, NUC6i3SYB, i3-6100U, 15 GiB (corrected — see status note) |
| .5 | `dc1` | Samba AD DC (libvirt VM on the laptop), authoritative for `ad.ddupan.top` |
| .6 | `winadmin` | Windows Server 2025 (libvirt VM on the laptop) |
| .7 | `pve2` | Proxmox, ThinkCentre 2400GE 8G |
| .8 | `bao1` | OpenBao (libvirt VM on the laptop) — internal CA + secrets |
| .9 | `pve3` | Proxmox, ThinkCentre 2400GE 8G |
| .127 | `laptop` | "core" node: ZFS+NFS, k3s, netboot.xyz, libvirt host, OSPF **DR**, BGP |
| .10–.250 | — | **router DHCP pool** — do not statically allocate inside this |

### Other prefixes in play
| prefix | what |
|---|---|
| `10.60.0.0/24` | SDN `labnet` (VLAN **100**), gateway `10.60.0.1` on vyos `eth1` |
| `10.61.0.0/24` | SDN `retronet` (VLAN **110**), gateway `10.61.0.1` on vyos `eth2` |
| `10.42.0.0/16` | k3s pod CIDR (laptop) |
| `10.43.0.0/16` | k3s service CIDR (laptop) |
| `10.1.72.0/24` | WAN side of the IX |

### Routing
OSPF **area 0** across the LAN. Speakers: NEC IX (.1), VyOS (.2), laptop (.127, currently **DR**).
VyOS advertises the SDN subnets as **intra-area** networks — deliberately *not*
`redistribute connected`, which would leak every future interface and inject topology-blind E2
routes. Verified on the IX: `O 10.60.0.0/24 [110/2] via 192.168.10.2`.

---

## 4. What NetBox would need to model

Minimum to remove the duplication in §1:
- **Prefixes** + roles for the LAN and both SDN subnets, with the DHCP pool marked as a pool so
  static assignments can't collide with it.
- **VLANs** 100/110 and their VLAN group, linked to the prefixes.
- **IP addresses** for §3, each assigned to a device/VM interface.
- **Devices/VMs**: 3 PVE nodes, the laptop, the IX, and the VMs (`vyos-rtr`, `dc1`, `winadmin`, `bao1`).
- **Interfaces**: notably vyos `eth0/eth1/eth2` and which VNet each attaches to.

Then the consumers that should read from it rather than hold their own copy:
1. `proxmox/ansible/roles/pve_sdn` — VNet name/tag list
2. `proxmox/ansible/roles/vyos_router` — interface addresses **and** the OSPF network list
3. `samba-ad/ansible` — `samba_ad_extra_a_records` (currently hand-listed)
4. possibly `proxmox/ansible/inventory/hosts.yml` — via `netbox.netbox.nb_inventory`

**Design question to answer, not assume:** does NetBox become the *authoring* surface (edit in the
UI, generate YAML/config) or a *derived mirror* (YAML stays authoritative, NetBox is populated from
it)? The repo's whole pattern is git-authoritative, so a UI that must be clicked to change routing
would be a regression. Consider `netbox-as-code`-style sync where git remains the input.

---

## 5. Existing conventions — match these

Repo root: `/home/panxiao81/services` (git, **but nothing is committed yet** — large untracked tree).

- **Ansible** per service: `<svc>/ansible/{ansible.cfg,inventory/hosts.yml,group_vars,roles/,*.yml}`.
  Style: `host_key_checking = False`, `callback_result_format = yaml`, heavy WHY-comments in roles,
  `retries`/`until` on anything touching the internet.
- **Terraform** per service: `<svc>/terraform/{versions,main,variables,outputs}.tf`, local state,
  `.gitignore` for `*.tfstate`. Auth from the ambient CLI session.
  Example: `openbao/terraform/` manages OpenBao's API surface.
- **Tooling**: Python CLIs via `uv`. Ansible is installed as
  `uv tool install ansible-core --with ansible --with paramiko`.
  ⚠️ `uv tool install ansible` alone only exposes `ansible-community`, not `ansible-playbook`.
- **Secrets**: plaintext but **gitignored** (`samba-ad/ansible/group_vars/all/vault.yml`,
  `proxmox/vyos/credentials.yml`). OpenBao (`bao.ad.ddupan.top`) is the real secrets store and the
  internal CA; it has a Terraform config already.
- **Kubernetes**: single-node k3s on the laptop. Manifests live per service
  (`smtp-relay/*.yaml`, `k3s/coredns-custom.yaml`). Authelia is Helm + `values.yaml`.

Ownership boundary already established for OpenBao and worth copying: **Terraform owns API-level
configuration, Ansible owns the machine and anything Terraform must not own** (key material,
secrets it cannot read back).

---

## 6. Constraints that will bite you

- **The WAN fails at random.** Bad ISP, cannot be changed. Any download/pull needs retries. DNS has
  flapped repeatedly. Do NOT go debugging the router for this — it has been checked
  (utilization "calm", memory 30%, 0 NAPT failures, upstreams fine).
- **Internal DNS must never depend on the WAN.** k3s CoreDNS sends `ad.ddupan.top` straight to the
  DC and NXDOMAINs the dead search suffixes (`k3s/coredns-custom.yaml`). PVE nodes use the DC first.
  If a pod times out resolving *anything*, suspect this first.
- **k3s pods inherit `ndots:5` + the node's search list** — names with <5 dots try every suffix
  first. This already caused a CrashLoopBackOff that looked like a service bug.
- **The cluster holds nothing critical** and has **no HA**. LINSTOR `place-count 2`.
  Guests are disposable; do not design as if they are not.
- **Storage**: `pve-rg` (SSD, ~187 GiB) and `pve-rg-hdd` (HDD, ~931 GiB) are LINSTOR/DRBD;
  `laptop` is NFS (~560 GiB free) for ISOs/templates/backups, **not** VM disks.

### Where to run NetBox
Most natural: the existing **k3s on the laptop** (`.127`), same pattern as Authelia/smtp-relay —
Helm or manifests in `netbox/`, Postgres available via the shared `shared-postgresql` cluster in
namespace `shared-db`. Alternative: a VM on the PVE cluster. Note the laptop is *not* a PVE member
and is the single point of failure for k3s, NFS, the AD DC, and OpenBao already.

**SSO is available and expected**: Authelia is the OIDC provider (`https://auth.ddupan.top`), backed
by Samba AD over verified LDAPS. Grafana/Gitea/OpenBao are already clients — wire NetBox the same
way rather than inventing local accounts. AD group → app-role mapping is the established pattern
(e.g. `pve-admins` → Proxmox `Administrator`).

---

## 7. Useful access

| target | how |
|---|---|
| PVE nodes | `ssh root@192.168.10.{4,7,9}` (key auth from the laptop) |
| VyOS | `ssh vyos@192.168.10.2`; op-mode non-interactively needs `/opt/vyatta/bin/vyatta-op-cmd-wrapper <cmd>` |
| NEC IX | netmiko `nec_ix_telnet`, creds in `~/scripts/netrestart/web/net.py`. `show running-config`/`show config` do **not** work — use `show ip route`, `show utilization`. No `show ip ospf neighbor` either; check adjacencies from VyOS. |
| k3s | `kubectl` on the laptop |
| OpenBao | `bao login -method=oidc` (browser); `~/.vault-token` |

Agent memory for this project lives in
`~/.claude/projects/-home-panxiao81-services/memory/` — read `MEMORY.md` first; the entries on
`homelab-proxmox-cluster`, `vyos-router-sdn`, and `flaky-wan-isp` are directly relevant.

---

## 8. Suggested first steps

1. Read the memory files above; do not re-derive the topology.
2. Decide **authoring vs mirror** (§4) — this shapes everything else.
3. Stand up NetBox (k3s + shared Postgres + Authelia OIDC), no data yet.
4. Model §3 by hand for the LAN + the two SDN prefixes. Check whether it actually reads better
   than the current YAML before going further.
5. Only then attempt generation: start with the **one** case that is genuinely error-prone —
   the VyOS OSPF network list plus its interface addresses, which today must be kept in sync
   with the PVE SDN VNets by hand.
6. Report back whether it earns its place. "It does not, here is why" is a valid outcome.

## 9. Outcome (2026-07-26)

Steps 1–5 done. **It earns its place on the case step 5 nominated**, and on one more:

- **Authoring vs mirror (§4) — answered: derived mirror.** `terraform/topology.yml` in git
  is authoritative; Terraform applies it. Nothing is authored by clicking.
- **VyOS OSPF generation — exact.** `generate/vyos-ospf.py --diff` → `matched=8,
  generated_only=0, live_only=0` against the live router.
- **AD DNS records (§4 item 3) — working.** `generate/samba-a-records.py --diff` found
  `retrolab` had a live A record but was missing from NetBox: the cross-check §1 says the
  current arrangement lacks.
- **Still unproven:** §4 items 1 (PVE SDN VNet list) and 4 (`nb_inventory` as the real
  Ansible inventory). Nothing yet *consumes* NetBox in anger — until an Ansible role reads
  from it, this is a second copy of the truth rather than a replacement for one.
