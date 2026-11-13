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
| Cinc (Chef) | `infrastructure/chef/` (cookbooks in the `homelab-cookbooks` repo) | policies + locks; `converge.py` bootstraps the client over SSH and converges nodes in parallel (`--why-run` = preview); first SPIRE enrollment is `ansible/enroll.yml`; no server; CI (`chef.yml`) why-runs PRs and applies on merge |

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

- **CI 的依赖下载经 Artifact Keeper**（`ci-actions/setup-artifact-keeper`，`https://artifacts.lab.ddupan.top`）：
  pypi、npm、Go 模块、Ansible Galaxy、Terraform provider 都走内部 pull-through 缓存。lockfile 里**写公共
  registry 的地址是标准形式**，不是绕过代理：npm 按 `.npmrc` 的 `registry=` 把 `package-lock.json` 里的
  `registry.npmjs.org` 改写到代理，uv 用 `UV_DEFAULT_INDEX`。Renovate 生成的 lockfile 就是公共地址；
  lockfile 的 resolved 地址在公共 registry 与代理之间切换不改变实际下载路径，不算供应链变化。
- Python CLIs via **uv**. Ansible specifically:
  `uv tool install ansible-core --with ansible --with paramiko --with pywinrm --with hvac`
  ⚠️ `uv tool install ansible` alone exposes only `ansible-community`, **not** `ansible-playbook`.
  ⚠️ `pywinrm` is not optional if you touch `windows_admin` hosts — without it every
  `ansible.windows.*` task dies with "No module named 'winrm'". It was missing from the
  installed env on 2026-07-26 because this line used to omit it. (`requests-ntlm`, needed
  for the inventory's `ntlm` transport, comes in transitively with pywinrm.)
  ⚠ `hvac` likewise: `community.hashi_vault` lookups (Bao secrets in plays) fail with a
  `no_log`-censored error without it. Added 2026-10-04.
- `deb822_repository` is **`ansible.builtin`**, not `community.general`.
- Network devices (VyOS) use `ansible.netcommon.network_cli`, not ssh/python — they have no
  Python interpreter. Prefer `vyos_config` with explicit `set` lines over the collection's
  resource modules, which lag upstream syntax.
  ⚠ `cli-shell-api showConfig --show-active-only --show-cfg1 load-balancing` 在现场并未
  限定为 LB 子树，而是输出完整配置（含密钥）。不要把尾随节点名当作过滤条件；
  先在路由器端严格提取所需配置段，再返回输出，不将完整配置送入工具日志。
  ⚠ A set-lines-only role **cannot change a multi-value node** — `set` appends. Changing
  e.g. `option wins-server` or `name-server` leaves the old value live *and* saved to
  `config.boot`; the diff only shows the addition, so it reads as a clean replace. Grep the
  running config (`show configuration commands | match <node>`) after any value change and
  `delete` the stale one out of band.

## Secrets

- **OpenBao** (`bao.lab.ddupan.top`, host .8) is the real secrets store and the **internal CA**.
  ⚠ Always by HOSTNAME — its Let's Encrypt cert has DNS SANs only, so `192.168.10.8` and
  `127.0.0.1` both fail TLS verification. The old `bao.ad.ddupan.top` stays valid long-term:
  the AIA/CRL/ACME URLs in certs bao has already issued, and the ACME accounts of
  cert-manager, PVE and dc1, point at it.
- **On the dev machine, log in to Bao with SPIRE, and get homelab secrets that way first.**
  Use `auth/jwt-spire` with role `local-development` (`platform/spire/README.md`). The
  identity matches uid 1000, so it does not work under `sudo`. The 5-minute token can read and
  write `kv/k8s/*` and `kv/infra/*` and sign `ai-agent` SSH certs. Agents should not look for
  the same secret elsewhere or ask for a `BAO_TOKEN` unless this fails.
  `bao login -method=oidc` is for a person doing what that policy does not allow, such as
  applying `infrastructure/openbao/terraform` locally.
- **Kubernetes Secrets come from OpenBao** via External Secrets Operator (`platform/external-secrets/`),
  which authenticates with its own ServiceAccount JWT — no credential is stored in the cluster.
  The gitignored `<svc>/secret.yaml` files remain as **break-glass** for when bao is down.
- **Ansible vaults are `ansible-vault` ENCRYPTED and committed**
  (`infrastructure/samba-ad/` and `infrastructure/openbao/` `ansible/group_vars/all/vault.yml`). The password is
  `.vault_pass` (gitignored), wired into every `ansible.cfg` as `vault_password_file`.
- Still plaintext-but-**gitignored**, because nothing consumes them as Ansible vars:
  `infrastructure/proxmox/vyos/credentials.yml` (referenced only in an inventory comment) and
  `infrastructure/proxmox/pxe/answer/*.toml` (read by the PXE installer).
- **Never** print, copy, or commit live credentials. The tailscale-operator OAuth client lives in
  Bao `kv/k8s/tailscale-operator` (Flux since 2026-11-03); any local gitignored
  `apps/tailscale/helm.sh` is obsolete and still holds a live copy — delete it rather than reuse it.

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
- ⚠ **But check the VPN before blaming the WAN** — though its blast radius shrank.
  `openvpn-client@naist` (tun0) used to accept **58 pushed split-tunnel routes** (Cloudflare
  `104.21/16`, `172.67/16`, Fastly `151.101/16`, Microsoft, CloudFront, Akamai); a dead tunnel
  blackholed all of them, crash-looping Gitea and breaking `pypi.org` on 2026-07-28. **Since
  2026-09-11** `naist.conf` has `pull-filter`s that accept only NAIST's own routes
  (`163.221.0.0/16`, `192.218.128.0/23`, `2001:df3:540::/48`), so CDNs no longer go via tun0.
  The failure mode is unchanged inside that scope: when the tunnel dies, systemd still reports
  `active running`, the routes stay, and NAIST addresses — including its public site
  `www.naist.jp` (163.221.8.230) — blackhole from the laptop and from **pods** (host routing
  table) while working fine from outside. `NaistVpnDown` (blackbox probe) now alerts on this.
  Diagnose with `ip route get <failing-ip>` (`dev tun0` = the VPN ate it) and
  `journalctl -u openvpn-client@naist` (repeated `TLS key negotiation failed` = no answer on
  UDP 1194). openvpn already retries every 5 min, so `systemctl restart` rarely helps then.
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
  it gateways both SDN VNets and speaks BGP to the IX. Consequence to remember: **fencing is now armed
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
- **A free-looking port on 192.168.10.127 may not be free.** Non-root `ss` hides
  `docker-proxy`, and k3s `LoadBalancer` services (svclb hostPorts, e.g. spire-server on
  `:8081`) own `.127:<port>` purely through iptables — nothing to see in `ss` at all.
  kube-proxy's DNAT runs before Docker's, so a clashing compose mapping fails *silently*:
  clients reach the k8s service instead. Check `sudo ss -tlnp`, `sudo iptables -t nat -S |
  grep 'dport <port>'` and `kubectl get svc -A` before picking one. Bit pdns on 2026-10-04.
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
- `infrastructure/incus/` — Incus on the laptop, for LXC and new Linux VMs (libvirt and bare-metal
  k3s stay). **CI owns it**: the root is in `TF_ROOTS`, so main is the desired state and manual
  changes to Terraform-managed resources are reverted on the next merge. CI reaches
  `https://192.168.10.127:8443` with a 30-minute client cert that `tf.py` mints per call from Bao
  `pki-incus` — a standalone root, **never chain it under `pki/`**: Incus has
  `core.trust_ca_certificates=true`, so any unexpired cert from that CA is full admin, i.e. laptop
  root. `server.ca` is the trust anchor and Ansible's (`access.yml`); CI cannot grant itself access.
  Locally use `python3 infrastructure/incus/run.py terraform …` (unix socket, S3 state).
  ⚠ **cloud-init config only takes effect at instance creation** — the image templates render the
  seed with `when: [create, copy]`, so editing `cloud-init.*` on an existing instance does nothing,
  even after reboot or `cloud-init clean`. Changing an address or initial setup means rebuilding.
  ⚠ Don't set `ssh_pwauth` in user-data: it writes a partial `sshd_config` before openssh-server is
  installed, dropping `UsePAM yes`, and locked-password accounts are then refused. Restarting
  `incus.service` is safe for running instances (`KillMode=process`).
- `platform/envoy-gateway/` — **the LAN ingress**. Gateway API; Envoy holds 192.168.10.127 and
  routes `*.ad.ddupan.top` by Host header. Adding a service = an `HTTPRoute` (external-dns
  publishes its `*.lab.ddupan.top` name; no new `ad.ddupan.top` records) + a health probe in `platform/observability/metrics/probes/probes.yaml`
  (and removing one = deleting its probe); no cert work (see `platform/cert-manager/`). There is **no
  forward-auth** at the Gateway (it went with Authelia): an app needing login or AD-group→role
  mapping must do it itself as an OIDC client of iam-login. An app with **no login at all** (e.g.
  `weed admin`) gets one at the gateway instead: an Envoy Gateway `SecurityPolicy` with `oidc` against
  iam-login plus a `groups` claim rule, and a NetworkPolicy so the port is reachable only from Envoy —
  copy `apps/seaweedfs/securitypolicy-admin.yaml`. No oauth2-proxy. ⚠ Keep its explicit
  `authorizationEndpoint`/`tokenEndpoint`: without them EG fetches discovery once, never retries, and a
  failed fetch silently drops the OIDC filter (policy `Accepted=False`, users see "Jwt is missing").
- `platform/cert-manager/` — two ClusterIssuers: `letsencrypt` (DNS-01 via Cloudflare) and
  `bao-acme` (OpenBao internal PKI). One `*.ad.ddupan.top` wildcard serves every LAN
  service, deliberately, so per-host names stay out of Certificate Transparency logs.
- **IPAM keeps only address pools** (`infrastructure/network/ipam.yml`; plan and routing roles in its README); the
  used set is **DNS** — creators register their own names in `lab.ddupan.top`, and
  `generate.py --next-free <prefix>` reads the live zone (needs `PDNS_API_KEY`).
  NetBox was evaluated and retired 2026-10-04:
  a derived mirror nobody read, and too heavy for the single node. Do not reintroduce a UI SoT.
- **A DNS record lives with whatever creates the thing it names** (incus Terraform: ayatori-*;
  cloudflared: tunnel CNAMEs from the ingress list; etcd `lxc.yml`: etcd-pve*). Only hosts no
  code creates (bare metal, hand-built VMs, VIPs) go in `infrastructure/dns/terraform/hosts.tf`.
  Do not recentralise records into one file "for overview" — that was the AD-era compromise
  dismantled 2026-10-09; the same rule is why there is no `terraform_remote_state` anywhere.
- `archive/keycloak/` and `archive/casdoor/` are retired IdP experiments; **iam-login** (`apps/iam-login/`, `sso.ddupan.top`) is the
  identity stack. Authelia (`auth.ddupan.top`) was retired 2026-10-11.
