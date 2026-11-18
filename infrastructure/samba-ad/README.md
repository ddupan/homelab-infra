# Samba Active Directory Domain Controller

Samba AD DC is the **identity source of truth** for the whole environment: Kerberos,
LDAP, DNS, SMB and Group Policy — a real Active Directory domain that Windows VMs can
domain-join and be GPO-managed, **without a licensed Windows Server as the DC**.

Consumers layered on top (later docs):
- **Samba file server** — domain member serving SMB shares.
- **Linux clients** — `realmd`/`sssd` domain join for central login.
- **iam-login** (`sso.ddupan.top`) — binds as the user over LDAPS → OIDC web SSO; reads users and groups
  outside a sign-in (console lookups, account checks) as the read-only `svc-iam-login`.

This document covers **Phase 1 (the DC)** and **Phase 2 (the Windows admin box)** only.

**Everything here is managed as code with Ansible** — see `ansible/`. The shell
commands in §1–§2 are documentation of *what the roles automate*, not steps to run by
hand. Run the playbooks.

---

## Ansible quickstart

```bash
cd ansible

# 1. one-time: ansible + collections + WinRM lib
#    (uv-installed ansible: uv tool install ansible-core --with ansible --with pywinrm --with requests-ntlm)
ansible-galaxy collection install -r requirements.yml

# 2. set your values (already filled in for ad.ddupan.top / DDUPAN / 192.168.10.5)
$EDITOR group_vars/all/vars.yml     # realm, netbios, DC IP, forwarder, KMS host
$EDITOR inventory/hosts.yml         # DC + Windows box addresses
# admin passwords: Bao kv/infra/samba-ad (administrator_password, win_local_admin_password);
# plays that need them read it at start, so export VAULT_TOKEN (SPIFFE local-development login)
bao kv put -mount=kv -cas=0 infra/samba-ad administrator_password=@/dev/stdin win_local_admin_password=…

# 3. create the VM locally (libvirt + Ubuntu cloud image + cloud-init)
ssh-keygen -t ed25519               # if you don't have ~/.ssh/id_ed25519.pub yet
ansible-playbook create-dc-vm.yml   # boots dc1 on br0 at 192.168.10.5

# 4. provision the domain, then verify
ansible-playbook provision-dc.yml --ask-vault-pass
ansible-playbook provision-dc.yml --ask-vault-pass --tags verify

# 5. join + configure the Windows admin box (needs WinRM reachable)
ansible-playbook join-windows.yml --ask-vault-pass
```

Re-running is safe: domain provisioning is guarded by the `sam.ldb` database, so a
second run is a no-op there and only reconciles config drift.

**Layout**

| Path | Purpose |
|---|---|
| `roles/dc_vm/` | creates the DC VM locally via libvirt + cloud-init |
| `roles/samba_ad_dc/` | provisions the DC (§1) — idempotent |
| `ansible/collections/ansible_collections/ddupan/homelab/` | repository-local collection containing the Samba DNS module and its `ansible-test` tests |
| `roles/samba_ad_dc/tasks/verify.yml` | smoke tests (`--tags verify`) |
| `roles/samba_ad_dc/tasks/legacy.yml` | opt-in retro-client protocols (§ Retro clients) |
| `roles/windows_vm/` | unattended-installs the Windows Server 2025 admin box (§2.0) |
| `roles/win_domain_join/` | joins Windows box, installs RSAT, KMS activation (§2) |
| `group_vars/all/vars.yml` | all non-secret settings — **edit this** |
| `tasks/bao-secrets.yml` | reads the admin passwords from Bao `kv/infra/samba-ad` at play start |
| `inventory/hosts.yml` | DC + Windows hosts |

Static DNS records are declared in `ansible/group_vars/all/dns.yml`. The role manages
only those RRsets and deliberately leaves Samba-generated AD locator records alone.
New service names go to `lab.ddupan.top` (PowerDNS), not here; this list only shrinks.

---

## 0. Decisions — fill these in before touching anything

These map 1:1 onto `ansible/group_vars/all.yml`.


| Item | Value | Notes |
|---|---|---|
| DNS realm | `AD.DDUPAN.TOP` | Delegated subdomain of `ddupan.top`. Never `.local`. |
| NetBIOS / short name | `DDUPAN` | ≤15 chars, uppercase, no dots. Windows-visible short domain. |
| DC hostname (FQDN) | `dc1.ad.ddupan.top` | |
| DC static IP | `192.168.10.5/24` | On `br0`; free in the `.2–.9` range. **Must stay static.** |
| Gateway | `192.168.10.1` | |
| Domain admin | `Administrator` | password from the vault |
| Forwarder DNS | `192.168.10.1` | where the DC forwards non-AD lookups |
| Windows admin box | `192.168.10.6` | RSAT/GPMC station |

> The example shell in §1–§2 still shows `example.com`-style placeholders for
> readability; the **live values above** are what `group_vars/all.yml` actually sets.

---

## 1. Provision the DC VM

> Automated by `roles/samba_ad_dc`. The commands below are what each task does.

**Base:** Debian 12 (or Ubuntu 24.04 LTS) VM — a **full VM, not LXC**. The DC is a
stateful pet; a VM avoids LXC keyring/namespace quirks with Kerberos. (The VM must
already exist and be reachable over SSH; this role configures the OS, it does not
create the VM — see "VM lifecycle" below.)

### 1.1 Host prerequisites

```bash
# Static IP, correct hostname, and time sync are non-negotiable.
hostnamectl set-hostname dc1.ad.example.com
timedatectl set-ntp true          # or install chrony; Kerberos dies on >5min skew
apt update && apt install -y chrony
```

`/etc/hosts` — the DC must resolve its own FQDN to its **real** IP (not 127.0.1.1):

```
10.10.10.10   dc1.ad.example.com   dc1
```

### 1.2 Free up port 53

Samba's internal DNS must bind `:53`. Disable the `systemd-resolved` stub listener:

```bash
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/no-stub.conf
systemctl restart systemd-resolved
# Point the DC at itself for DNS:
ln -sf /run/systemd/resolve/resolv.conf /dev/null 2>/dev/null || true
printf 'nameserver 10.10.10.10\nsearch ad.example.com\n' > /etc/resolv.conf
chattr +i /etc/resolv.conf   # stop NM/cloud-init from clobbering it
```

### 1.3 Install and provision

```bash
apt install -y samba krb5-config winbind smbclient ldb-tools

# Stop distro auto-started daemons; the AD DC runs the unified `samba` service only.
systemctl disable --now smbd nmbd winbind 2>/dev/null || true
systemctl unmask samba-ad-dc

# Clean any stock config so provision writes fresh
mv /etc/samba/smb.conf /etc/samba/smb.conf.orig 2>/dev/null || true

samba-tool domain provision \
  --use-rfc2307 \
  --realm=AD.EXAMPLE.COM \
  --domain=EXAMPLE \
  --server-role=dc \
  --dns-backend=SAMBA_INTERNAL \
  --adminpass='CHANGE-ME-Strong.Passw0rd' \
  --option="dns forwarder = 10.10.10.1"

systemctl enable --now samba-ad-dc
```

> **`--use-rfc2307` is mandatory and cannot be cleanly added later.** It stores POSIX
> uid/gid in the directory so Linux clients get stable IDs.

### 1.4 Wire Kerberos

```bash
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
```

### 1.5 Smoke tests

```bash
# LDAP / domain sanity
samba-tool domain level show

# Kerberos ticket for the admin
kinit administrator@AD.EXAMPLE.COM && klist

# DNS: the DC must resolve its own SRV records
host -t SRV _ldap._tcp.ad.example.com.
host -t SRV _kerberos._udp.ad.example.com.
host -t A   dc1.ad.example.com.

# SMB: default shares present
smbclient -L localhost -U administrator
```

All four must succeed before moving on. **If anything AD-related "doesn't work"
later, it is almost always DNS** — every member must use the DC as its resolver, and
the DC must resolve itself.

---

## 2. Windows admin box (your one long-lived Windows VM)

You need exactly **one** Windows VM as the GPO authoring / AD management station.
Samba stores GPOs but you edit them with the Windows GPMC; `samba-tool gpo` only
covers basic operations.

### 2.0 Build it as code — `create-windows-vm.yml` (role `windows_vm`)

Fully unattended install of **Windows Server 2025 Standard (Desktop Experience)** from
your ISO, the Windows analogue of the DC's cloud-init:

```bash
ansible-playbook create-windows-vm.yml    # ~30-45 min: install + reboots + WinRM setup
```

What it does:
- Creates zvol `data/vm/winadmin`, **UEFI/GPT**, **virtio disk + virtio NIC**.
- Renders `autounattend.xml` (edition index 2, locale zh-CN, GVLK, admin pw from vault),
  packs it on a seed ISO. **Injects virtio drivers** (`viostor`/`NetKVM`, 2k25) during
  Setup via `DriverPaths` off the `virtio-win` ISO so Setup sees the virtio disk.
- `FirstLogonCommands`: static IP `192.168.10.6` → DC DNS, **WinRM-over-HTTPS** listener
  (self-signed), open 5986, **enable RDP**, and run **virtio-win guest tools** (QEMU
  guest agent + balloon).
- Gets past "Press any key to boot from CD" with `virsh send-key`, waits for WinRM,
  then ejects install media and deletes the password-bearing seed ISO.

Then hand off to §2.1–2.4 below, automated by `join-windows.yml` (role `win_domain_join`)
— domain join → RSAT → KMS activate. Needs WinRM reachable; the commands below are what
those tasks do.

> The seed ISO holds the local admin password in cleartext while Setup runs; the play
> removes it once WinRM is up. Edition index / GVLK / locale are role vars — verify the
> index against your ISO with `wiminfo …\sources\install.wim`.

### 2.1 Point it at the DC for DNS

On the Windows VM's NIC, set **DNS server = `10.10.10.10`** (the DC). This is the
single most common failure point — a Windows box using any other resolver cannot
find the domain.

### 2.2 Join the domain

`System → Rename this PC (advanced) → Domain: ad.example.com` →
authenticate as `EXAMPLE\Administrator` → reboot.

### 2.3 Install RSAT (management tools)

On Windows 10/11:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0
```

This gives you **AD Users & Computers**, **Group Policy Management (GPMC)**, and the
DNS console — the graphical admin surface for the domain.

### 2.4 Activate against existing KMS

This repo already runs `vlmcsd` (KMS emulator). Activate the Windows VM against it so
the admin box stays licensed:

```powershell
slmgr /skms kms.example.com:1688     # your vlmcsd host
slmgr /ipk <GVLK-for-this-edition>   # public KMS client setup key for the edition
slmgr /ato
```

---

## VM lifecycle (creating the box as code)

The VM itself is created by `roles/dc_vm` (`create-dc-vm.yml`), which runs against
the **local libvirt host**:

1. Downloads the **latest Ubuntu 24.04 LTS cloud image** (`.../noble/current/…`) once
   into `/var/lib/libvirt/images/base/`.
2. Creates a **ZFS zvol** `data/vm/dc1` (`dc_vm_disk_gb`, default 25 GB, 16K
   volblocksize — matching `data/vm/win2k25`) and writes the image into it raw with
   `qemu-img convert`. cloud-init `growpart` expands the rootfs to fill it on first boot.
3. Renders `user-data` / `meta-data` / `network-config` from templates and packs a
   **NoCloud seed ISO** (`genisoimage`, volid `cidata`). The seed sets a static IP
   (`192.168.10.5/24`, gw `.1`), the hostname, and injects your SSH public key.
4. `virt-install --import` attaches the zvol (`/dev/zvol/data/vm/dc1`, virtio) and the
   seed ISO, boots the domain on bridge **`br0`**, then waits for SSH.

It's idempotent — if the `dc1` domain exists the block is skipped; the zvol write is
separately guarded so a re-run never clobbers an existing disk.

**Before running:** you need an SSH keypair; the play injects
`dc_vm_ssh_pubkey_file` (default `~/.ssh/id_ed25519.pub`). Generate one with
`ssh-keygen -t ed25519` if absent — the play fails fast otherwise.

Tunables live in `roles/dc_vm/defaults/main.yml` (vCPU, RAM, disk, image URL,
bridge, gateway, `dc_vm_zvol_parent`). Alternatives (PXE via your existing `netboot/`, or a Debian base)
are still viable, but the contract is the same: hand `samba_ad_dc` a booted VM with a
static IP matching `samba_ad_dc_ip`, SSH reachable as the `ansible` user.

---

## 3. Operations

### Add users / groups (either UI or CLI)

```bash
samba-tool user create alice
samba-tool group add engineering
samba-tool group addmembers engineering alice
```

…or do it graphically from the Windows admin box via **AD Users & Computers**.

### Service accounts (`samba_ad_service_accounts`)

Bind accounts for apps live in `group_vars/all/vars.yml`, created by `provision-dc.yml --tags accounts`.
All current entries use `bao_path` (svc-pve and svc-poweradmin moved from the old `vault.yml` on 2026-11-18;
`password:` still works for a value supplied some other way). A `bao_path` account has its password
**generated by the play** on creation and stored only in Bao at that path
(`username` = UPN, `password`), where the consumer's ExternalSecret reads it. Such runs need `VAULT_TOKEN` with
create/read there. If the account exists but Bao has no password, the play stops rather than invent one: rotate
with `samba-tool user setpassword` and write the new value to that path.

### Backups (`backup-dc.yml`, role `samba_ad_backup`)

dc1 is the only DC. The domain SID, accounts, password hashes and krbtgt keys cannot be rebuilt from code,
so this backup is the only way back after losing the VM.

`samba-backup.timer` runs `samba-tool domain backup offline` every day at about 03:30. Offline mode reads the
database files directly under a lock. It needs no admin password, and the DC keeps serving while it runs.

| copy | where | kept |
|---|---|---|
| local | dc1 `/var/backups/samba/` | 7 newest |
| offsite | OCI bucket `dc1-backup`, GPG-encrypted to the YubiKey | 7 days, lifecycle rule |

dc1 can only *create* objects in that bucket (`infrastructure/oci/terraform/dc1-backup.tf`), so a compromised DC
cannot delete or overwrite older backups. After each successful upload, the script writes
`samba_backup_last_success_timestamp_seconds` to the node_exporter textfile directory.
`SambaBackupStale` fires when that is more than 36 h old, or when it is missing.

The offsite copy is encrypted to the same public key as the pg-prod dump and the k3s backup
(`infrastructure/openbao/ansible/roles/openbao/files/escrow-recipient.asc`). Decrypting it needs the YubiKey,
and there is no password to keep. Its [E] subkey expires on 2027-04-07. After that `gpg` fails and
`SambaBackupStale` fires, so update the recipient file when the subkey is rotated.

**First setup.** After CI applies the OCI root, copy the outputs `dc1_backup_access_key` and
`dc1_backup_secret_key` into Bao `kv/infra/dc1-backup` as `oci_access_key` and `oci_secret_key`. Then:

```bash
VAULT_TOKEN=... ansible-playbook backup-dc.yml --check --diff && VAULT_TOKEN=... ansible-playbook backup-dc.yml
ssh dc1 sudo systemctl start samba-backup.service   # first run; check the OCI console
```

**Restore** (new DC VM from `create-dc-vm.yml`, no `provision-dc.yml`):

1. Take the newest local archive. If it is gone, download the `.gpg` object from the OCI console and run
   `gpg -d samba-backup-<time>.tar.bz2.gpg > samba-backup-<time>.tar.bz2` (touch the YubiKey).
2. On the new VM (samba installed, not provisioned):
   `samba-tool domain backup restore --backup-file=<archive> --newservername=dc1 --targetdir=/var/lib/samba-restore`,
   then point smb.conf / the systemd unit at the restored tree. See the Samba wiki page
   "Back up and Restoring a Samba AD DC". The new server name must be one the domain has not seen before;
   if `dc1` is refused, use `dc2`.

### Monitoring — Cinc policy `samba-dc`

dc1 is a Cinc node (`infrastructure/chef/`, policy `samba-dc`, applied by CI on merge):
`homelab_base` installs Ubuntu's `prometheus-node-exporter` bound to `192.168.10.5:9100`; the cluster scrapes
it as `job=node-exporter, node=dc1` (`platform/observability/metrics/scrapes/samba-dc.yaml`), so
the generic host-health rules (disk, memory, failed units, PSI, clock sync) cover dc1 too.
AD-specific alerts live in `platform/observability/metrics/rules/samba-dc.yaml`:
`samba-ad-dc` unit state, Kerberos/LDAP/LDAPS reachability (blackbox, LDAPS verified by
hostname against the bao CA), LDAPS cert expiry, and the `samba-acme.timer` heartbeat.
DNS is probed separately (`dns-dc1`). No AD credentials are involved anywhere.

### Second DC (resilience) — easy now, painful to retrofit after an outage

On a second freshly-provisioned member (DNS pointed at `dc1`):

```bash
samba-tool domain join ad.example.com DC \
  -U"EXAMPLE\administrator" --dns-backend=SAMBA_INTERNAL
```

---

## 4. Gotchas cheat-sheet

- **DNS is the whole ballgame.** ~90% of "AD is broken" is a member not using the DC
  as its resolver, or the DC not resolving itself. Domain members point at
  `192.168.10.5` directly; non-domain LAN devices reach AD names via the router's
  conditional forward — see `router-dns-nec-ix.md`.
- **Time skew > 5 min → Kerberos silently fails.** Keep `chrony` healthy on the DC and
  all members.
- **Don't containerize the DC in K8s** — it fights K8s's DNS/networking model. VM only.
- **`--use-rfc2307` at provision time** or you lose stable Linux uid/gid mapping.
- **One share off the DC is fine for testing, but real shares belong on a member
  file server** (next doc), not the DC.
- **GPO editing needs the Windows RSAT box**; keep that one VM around.

---

## Retro clients (Win9x / NT4 / Windows 2000 / XP)

Modern Samba disables the old protocols these machines need (SMB1, NTLMv1, LANMAN,
DES Kerberos). Support is **opt-in** via `samba_ad_legacy_clients: true` in
`group_vars/all.yml`, which runs `roles/samba_ad_dc/tasks/legacy.yml` to inject the
insecure knobs and restart the DC.

> ⚠️ This materially weakens the **entire domain** — LM/NTLMv1 hashes are trivially
> crackable and SMB1 is wormable. Only enable it on an **isolated VLAN** for the retro
> machines. Ideally, don't weaken the primary DC at all: stand up a **dedicated legacy
> Samba member server** for file access and keep the DC strict. For domain *logon* of
> 9x/NT4 (below) the DC itself must speak old crypto, so segment the network instead.

What each era can actually do:

| Client | Domain **join** | Domain **logon** | SMB **share access** | What it needs |
|---|---|---|---|---|
| **Windows XP / 2003** (NT 5.1/5.2) | ✅ real AD join | ✅ Kerberos/NTLMv2 | ✅ | SMB1 (`server min protocol = NT1`). Mostly works with the toggle. |
| **Windows 2000** (NT 5.0) | ✅ real AD join | ✅ | ✅ | SMB1 **+** weak Kerberos crypto (DES) — `allow_weak_crypto`. Fiddly. |
| **Windows NT4** | ❌ (no Kerberos) | ✅ NT4-style (NTLM) | ✅ | NTLM + `allow nt4 crypto`. Joins as an NT4 domain, not AD. |
| **Windows 9x / ME** | ❌ (not a domain member) | ⚠️ NT-domain network logon only | ✅ | LANMAN auth + WINS. No Kerberos, ever. LM hashes only. |

The toggle turns on (see `legacy.yml`):

```
server min protocol = NT1        # SMB1 for XP/2000/NT4/9x
ntlm auth = ntlmv1-permitted     # NTLMv1
lanman auth = yes                # LANMAN — required by 9x, insecure
client lanman auth = yes
allow nt4 crypto = yes           # NT4 member logon
wins support = yes               # NetBIOS name resolution for 9x/NT4
```
plus `allow_weak_crypto = true` in `/etc/krb5.conf` for Windows 2000's DES Kerberos.

Practical notes for the oldest clients:
- **Win9x needs WINS**, not DNS — point the clients' WINS server at the DC's IP (or a
  legacy member running `wins support = yes`). Browsing relies on NetBIOS.
- **9x can't join** — it does an NT-domain *network logon* to a logon server and then
  accesses `\\server\share` with domain credentials. Set the client's "Logon to
  Windows NT domain" to `DDUPAN`.
- **Passwords:** after enabling weak crypto, accounts used by Win2000 may need a
  password reset so the DES/RC4 keys get regenerated with the new enctypes allowed.
- Keep these clients on `192.168.10.x` with the DC as WINS + gateway, firewalled off
  from anything you care about.

---

## 5. Linux Samba member fileserver (`join-member.yml`)

Joins a Linux host to the domain as a **Samba member fileserver** (`security = ADS`
+ winbind), so AD users/groups can authenticate to its SMB shares. Codified as the
`samba_member` role; runs against the `samba_members` inventory group.

```bash
# Inventory already has `laptop` (the KVM host, 192.168.10.127) under samba_members.
ansible-playbook join-member.yml --check --diff     # preview (safe; no real join)
ansible-playbook join-member.yml                    # join for real → creates LAPTOP$ in AD
ansible-playbook join-member.yml --tags verify      # re-run smoke tests only
```

What the role does, in order: install `winbind` + `libnss-winbind` + `krb5-user`
(**no `libpam-winbind`** — this is a fileserver join, not OS login) → write
`/etc/krb5.conf` for the realm → add a split-DNS drop-in → rewrite `smb.conf`
(`[global]` becomes an ADS member; existing shares preserved, original saved to
`smb.conf.pre-ads`) → add `winbind` to NSS `passwd`/`group` → `net ads join`
(guarded by `net ads testjoin`, so re-runs are no-ops) → start winbind → smoke tests.

Design choices:
- **RID idmap** (`idmap config DDUPAN : backend = rid`, range `10000-999999`) —
  algorithmic, deterministic, needs no RFC2307 attributes. The DC *is* `--use-rfc2307`,
  so switching to `backend = ad` for centrally-managed `uidNumber`/`gidNumber` is a
  later option (must be identical on every member). Administrator → uid `10500`.
- **Split-DNS is mandatory here.** The LAN router (`192.168.10.1`) does **not** answer
  realm SRV lookups, so the role drops `/etc/systemd/resolved.conf.d/ad-realm.conf`
  routing `ad.ddupan.top` → the DC (`192.168.10.5`), which is authoritative and fast.
- **`apt update` is OFF by default** (`samba_member_apt_update_cache: false`). That
  host's upstream DNS forwarder is flaky and a full refresh touches every repo in
  `sources.list.d`; the member packages are already in the local cache. Pass
  `-e samba_member_apt_update_cache=true` to force a refresh when DNS is healthy.
- Shares are data (`samba_member_shares` in the role defaults) — the guest `[win]`
  share and the Cockpit ZFS `include` are carried over verbatim.

Verify by hand: `sudo net ads testjoin` → *Join is OK*; `wbinfo --online-status`;
`getent group 'domain admins'`; `smbclient -L localhost -N`.

## Next docs

- ~~`samba-fileserver` — domain-member SMB shares.~~ **Done** — see §5 above.
- `linux-domain-join` — `realmd` + `sssd` (OS login, distinct from this fileserver join).
- `../../apps/iam-login/` — LDAPS user bind → OIDC web SSO.
