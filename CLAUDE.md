# Working in this repo

Homelab infrastructure-as-code. Independent service folders, no shared build or workspace
manifest. Most of what runs here is **live** — treat it as production for a household, not a
sandbox.

Persistent notes live in `~/.claude/projects/-home-panxiao81-services/memory/`. **Read
`MEMORY.md` first**; it indexes the topology, the incident log, and the traps. Do not re-derive
what is already recorded there.

## Layout

| stack | folders | pattern |
|---|---|---|
| Ansible | `infrastructure/proxmox/`, `infrastructure/samba-ad/`, `infrastructure/openbao/` | `<component>/ansible/{ansible.cfg,inventory/hosts.yml,group_vars/,roles/,*.yml}` |
| Terraform | per-component roots under `apps/` and `infrastructure/` | `<component>/terraform/{versions,main,variables,outputs}.tf`; states remain isolated |
| Kubernetes | `platform/` and `apps/` | manifests or Helm `values.yaml` owned by each component |

Single-node **k3s runs on the laptop (192.168.10.127)**, which is deliberately *not* a Proxmox
cluster member. It is also the NFS server, libvirt host (AD DC, OpenBao, Windows), and
netboot.xyz appliance — i.e. the single point of failure for most of the lab.

## Conventions

- **Comment the WHY, not the what.** Roles here explain why a setting exists and what breaks
  without it. Match that density; it is the main defence against re-learning the same traps.
- **Idempotency is the acceptance test.** A second run must report `changed=0`. If a task cannot
  be idempotent (a reconcile action), say so in a comment rather than leaving it ambiguous.
- **Terraform roots stay per-service, never merged into one central root.** Considered and
  rejected 2026-07-26: the roots use different providers *and* different interactive auth
  (`bao login -method=oidc`, `az login`, API tokens), so one shared root would need every
  credential valid simultaneously just to `plan`, and would put OpenBao's PKI in the blast
  radius of every apply.
- **Ownership boundary** (established for OpenBao, copy it): Terraform owns API-level
  configuration; Ansible owns the machine and anything Terraform must not own — key material,
  and secrets it cannot read back.
- Play separation: safely re-runnable baseline in `site.yml`; one-way or destructive operations
  get their own playbook (`cluster.yml`, `linstor.yml`) and often an extra `-e` flag.

## Tooling

- Python CLIs via **uv**. Ansible specifically:
  `uv tool install ansible-core --with ansible --with paramiko --with pywinrm`
  ⚠️ `uv tool install ansible` alone exposes only `ansible-community`, **not** `ansible-playbook`.
  ⚠️ `pywinrm` is not optional if you touch `windows_admin` hosts — without it every
  `ansible.windows.*` task dies with "No module named 'winrm'". It was missing from the
  installed env on 2026-07-26 because this line used to omit it. (`requests-ntlm`, needed
  for the inventory's `ntlm` transport, comes in transitively with pywinrm.)
- `deb822_repository` is **`ansible.builtin`**, not `community.general`.
- Network devices (VyOS) use `ansible.netcommon.network_cli`, not ssh/python — they have no
  Python interpreter. Prefer `vyos_config` with explicit `set` lines over the collection's
  resource modules, which lag upstream syntax.
  ⚠ A set-lines-only role **cannot change a multi-value node** — `set` appends. Changing
  e.g. `option wins-server` or `name-server` leaves the old value live *and* saved to
  `config.boot`; the diff only shows the addition, so it reads as a clean replace. Grep the
  running config (`show configuration commands | match <node>`) after any value change and
  `delete` the stale one out of band.

## Secrets

- **OpenBao** (`bao.ad.ddupan.top`, host .8) is the real secrets store and the **internal CA**.
  Authenticate with `bao login -method=oidc`. ⚠ Always by HOSTNAME — its Let's Encrypt cert
  has a DNS SAN only, so `192.168.10.8` and `127.0.0.1` both fail TLS verification.
- **Kubernetes Secrets come from OpenBao** via External Secrets Operator (`platform/external-secrets/`),
  which authenticates with its own ServiceAccount JWT — no credential is stored in the cluster.
  The gitignored `<svc>/secret.yaml` files remain as **break-glass** for when bao is down.
- **Ansible vaults are `ansible-vault` ENCRYPTED and committed**
  (`infrastructure/samba-ad/` and `infrastructure/openbao/` `ansible/group_vars/all/vault.yml`). The password is
  `.vault_pass` (gitignored), wired into every `ansible.cfg` as `vault_password_file`.
- Still plaintext-but-**gitignored**, because nothing consumes them as Ansible vars:
  `infrastructure/proxmox/vyos/credentials.yml` (referenced only in an inventory comment) and
  `infrastructure/proxmox/pxe/answer/*.toml` (read by the PXE installer).
- **Never** print, copy, or commit live credentials. `apps/tailscale/helm.sh` contains live OAuth
  values — leave them where they are.

**Rebuild order — bao comes first.** The whole chain is deliberately rooted in one hardware key:

1. **repo + YubiKey** → `gpg -dq .vault_pass.gpg > .vault_pass` (committed ciphertext, encrypted
   to cv25519 `5A6A04D1B216C64E`, the [E] subkey of `0166F47B5400ECC2`; **expires 2027-04-07**,
   re-encrypt when the subkey is rotated).
2. `.vault_pass` decrypts `infrastructure/openbao/ansible/group_vars/all/vault.yml` → provision + bootstrap bao.
   **infrastructure/openbao/ must never read its own secrets from bao** — `vault_openbao_cf_dns_token` is what
   gets bao its TLS cert, so that dependency cannot be inverted. This is why infrastructure/openbao/ stays on
   ansible-vault while everything built later may use `community.hashi_vault` lookups.
3. bao up → ESO syncs every Kubernetes Secret; other projects can look secrets up directly.

The bao root token is PGP-wrapped to the same key (`gpg -dq`, touch YubiKey) — see
`infrastructure/openbao/ansible/bootstrap-openbao.yml`. A copy of the vault password also lives at
`kv/infra/ansible-vault`, but that is convenience only: it is *inside* the thing being
recovered, so `.vault_pass.gpg` is the authoritative recovery path.

## Environment constraints

- **The WAN fails at random.** Bad ISP, cannot be changed. Anything that fetches from the
  internet needs `retries`/`until`. **Do not go debugging the router for this** — it has been
  checked thoroughly (see `flaky-wan-isp` memory).
- ⚠ **But check the VPN before blaming the WAN.** `openvpn-client@naist` (tun0) installs **58
  split-tunnel routes** capturing Cloudflare (`104.21/16`, `172.67/16`), Fastly (`151.101/16`),
  Microsoft `13.107.x`, AWS CloudFront and Akamai. When the tunnel dies, systemd still reports
  `active running` and **those routes stay installed**, blackholing everything that matches
  while `github.com` — not in the route set — keeps working, so it looks like selective CDN
  blocking or a bad ISP. **Pods inherit this**, since they use the host routing table. It
  crash-looped Gitea and broke `pypi.org` on 2026-07-28. Diagnose with
  `ip route get <failing-ip>` (`dev tun0` = the VPN ate it) and
  `ping -c2 -I tun0 163.221.48.1`; fix with `systemctl restart openvpn-client@naist`.
  `~/scripts/netrestart/main.py` bounces the WAN uplink and **cannot** fix this.
- ⚠ **IPv6 is broken on the laptop, and it looks like a VPN problem but is not.** `br0` has
  **no global IPv6 address** — `net.ipv6.conf.all.forwarding=1` (libvirt/k3s) makes the kernel
  default `accept_ra` to `0`, so SLAAC never runs, while NetworkManager still installs a v6
  default route. The only global v6 address on the box is `tun0`'s, so the kernel hands it to
  routes that egress `br0`: packets leave the LAN with the VPN's source address and nothing
  comes back, leaving sockets in `SYN-SENT` forever. **`ip route get` shows `dev br0` and looks
  innocent — the tell is the source address, not the device.** Diagnose with
  `ss -tnp | grep SYN-SENT` and `ip -6 addr show scope global`. `curl` hides it (Happy Eyeballs);
  **`.NET`/`pwsh` does not** — hence `DOTNET_SYSTEM_NET_DISABLEIPV6=1` for anything PowerShell.
  Real fix (unapplied, needs a change window): `net.ipv6.conf.br0.accept_ra=2`.
- **Interactive device-code logins deadlock under `!` and under plain redirection.** A `!`
  command's output is not shown until it exits, so a login code never appears and the process
  waits forever for a code you cannot see. PowerShell also buffers when redirected to a file.
  Run these under a PTY and read the log:
  `script -qfc "pwsh -NoProfile -File <script>" /tmp/.../log` backgrounded, then grep the log
  for the code. Used for the M365 DKIM scripts on 2026-07-28.
- **Internal name resolution must never depend on the WAN.** k3s CoreDNS routes `ad.ddupan.top`
  straight to the DC; PVE nodes use the DC first. If a pod times out resolving *anything*,
  suspect DNS search-domain fallout before the service itself.
- The Proxmox cluster is **almost entirely HA-free** and holds nothing critical; guests are
  disposable. **One exception (2026-07-26): `vm:100` (`vyos-rtr`) is an HA resource**, because
  it gateways both SDN VNets and speaks OSPF. Consequence to remember: **fencing is now armed
  cluster-wide**, so a node losing quorum self-reboots — and corosync has a single ring on the
  flat 1G LAN. See `infrastructure/proxmox/README-ha.md`; the watchdog is still `softdog` (cannot fence a
  frozen kernel) until each node is rebooted or hand-swapped.

## Working rules

- **Do not update `CHANGELOG.md`.** It is a frozen historical snapshot; requiring every PR
  to append to one shared text file caused needless conflicts and duplicated Git/PR history.
  Put durable service state and operational knowledge in the component README or runbook,
  agent-facing traps here, and let commits/PRs record individual changes.
- **Verify, don't assert.** Check the end state (`pvesm status`, `linstor node list`,
  `kubectl get pod`, `show ip route`) rather than trusting that a command "should have" worked.
  Several confident diagnoses in this repo's history were wrong until measured.
  Corollary: **test from a second host before concluding "the network is broken"**. A failure
  reproduced only on the laptop is a laptop problem — `ssh root@192.168.10.4` and retry there.
- **Scan for secrets case-INSENSITIVELY.** A live Postgres password reached a commit because
  the grep matched `password` but not `PASSWD:`. Match on content, not filenames: the worst
  finds of 2026-07-28 were in files called `values.yaml`, `accounts.json` and `auth.json`.
- **`.gitignore` does not untrack what is already staged.** Adding a rule after `git add`
  leaves the file in the index and it *will* be committed. Worse, `git check-ignore` skips
  indexed files unless you pass `--no-index`, so the obvious verification returns a false
  all-clear. Use `git check-ignore --no-index` and `git rm --cached` to actually remove it.
- **A `.tfplan` is a zip containing a full `tfstate`.** It walks straight past `*.tfstate`
  ignore rules. Ignore `*.tfplan` everywhere.
- **SPIRE CLI JSON can be an array of response blocks.** `spire-agent api fetch jwt
  -output json` in 1.15.3 returns blocks containing `svids` and `bundles`. Capture stdout
  privately and type-check before extracting fields; `list(response)` prints full tokens
  when the response is already an array. Never inspect credential payloads by printing
  their containers, and never put fetched JWTs in command arguments or Pod logs.
- **Quoting does not survive two ssh hops.** `ssh pve1 "ssh pve3 'cmd | qm monitor 103'"`
  loses the inner quotes — ssh re-joins argv with spaces, so the pipeline splits and the
  tail runs on the **jump host**. It fails silently if you discard stderr: a `screendump`
  ran on pve1 for ten minutes while I re-read one stale frame. Base64 the payload into a
  single token (`echo <b64> | base64 -d | bash`) and have the remote print something that
  proves freshness (an `mtime`, a timestamp).
- ⚠ **`pkill -f <pattern>` matches the shell that is running it.** Bitten three times in
  one session, including when the pattern only appears in the *start* command sitting on
  the same line. Bracket a character (`atmodem[.]py --conn[e]ct`) — but note that only
  works if the literal bracketed form is what is on your own command line, so put the kill
  in a **separate invocation** from the start.
- **Guard destructive commands.** Before `sgdisk`/`wipefs`/`vgremove`/`dd`, assert the target is
  what you think it is (`lsblk -dno TYPE` == `disk`). A wrong device once destroyed the LVM
  metadata on two live nodes. Derive parent disks from **sysfs**, never `lsblk -no PKNAME`
  without `--nodeps`.
- **Don't sit in poll loops.** Query the result directly; background genuinely long jobs and
  carry on. Waiting on a `serial: 1` playbook to answer a question one `ssh` would settle is
  wasted time.
- **Edit YAML with YAML-aware tools.** A regex sweep over a file with multiple literal blocks
  silently corrupted a Helm values file here. For Helm releases, `helm get values <rel> -n <ns>`
  is the reliable backup.
- Reach for `--check --diff` first on anything touching a live system.

## Service-specific notes

- `infrastructure/proxmox/` — **PVE has no floppy drive**, in the UI *or* the config schema, and `-nodefaults`
  means QEMU does not create one either. Retro guests get it through the `args` field:
  `qm set <vmid> -args "-drive if=floppy,format=raw,file=/mnt/pve/laptop/template/iso/<x>.img"`.
  `args` is appended last, so a trailing `-boot order=a` there also overrides PVE's own `-boot`
  if you need to boot the floppy. Changing `args` needs a **power cycle** (`qm reboot` is not
  enough); swapping the *medium* afterwards does not —
  `echo "change floppy0 /path/y.img" | qm monitor <vmid>` (`eject floppy0` first if you want to
  write the image from the host). Do not edit the image underneath a running guest.
  `roles/pve_floppy` puts a small web UI for exactly this on **pve1**
  (`https://pve1.ad.ddupan.top:8088` — by hostname, the cert has no IP SAN). One instance covers
  the cluster because `pvesh` proxies to whichever node owns the VM. It shells out as root rather
  than using an API token on purpose: **`args` is root@pam-only** — the check is a literal
  `$authuser eq 'root@pam'` and a token's authuser is `root@pam!name`, so no token, however
  privileged, can set it. Login is delegated to PVE's `/access/ticket` (via pvedaemon on
  `127.0.0.1:85`, so no password ever lands in a process argv), which means **PAM and AD-over-LDAPS
  both work with no PAM or LDAP code in the app** — plus a `Sys.Modify` on `/` check, because
  authenticating only proves who you are and this app points VMs at host files.
- `platform/envoy-gateway/` — **the LAN ingress**. Gateway API; Envoy holds 192.168.10.127 and
  routes `*.ad.ddupan.top` by Host header. Adding a service = an `HTTPRoute` + a DNS A
  record in `samba-ad`; no cert work (see `platform/cert-manager/`). Authelia forward-auth is
  available per-route via a `SecurityPolicy` — `apps/netbox/securitypolicy.yaml` is the worked
  example, and it is what makes AD-group→role mapping possible for apps whose own SSO
  cannot do it.
- `platform/cert-manager/` — two ClusterIssuers: `letsencrypt` (DNS-01 via Cloudflare) and
  `bao-acme` (OpenBao internal PKI). One `*.ad.ddupan.top` wildcard serves every LAN
  service, deliberately, so per-host names stay out of Certificate Transparency logs.
- `apps/netbox/` — **deployed** at `netbox.ad.ddupan.top`, still an *evaluation*: nothing
  consumes it yet, so deleting it breaks nothing. `terraform/topology.yml` is the
  authoritative data (git → NetBox, a derived mirror — never edit via the UI);
  `apps/netbox/terraform/` applies it. `generate/*.py` read back out and `--diff` against live
  systems. Read `apps/netbox/README.md`; `CONTEXT.md` is the original brief.
- `archive/keycloak/` and `archive/casdoor/` are retired IdP experiments; Authelia is the only identity stack.
