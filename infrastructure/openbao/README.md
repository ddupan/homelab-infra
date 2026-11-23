# OpenBao

Self-hosted secrets management + internal CA (SSH cert authority, dynamic secrets,
KV, PKI, transit) — the root-of-trust for AI agents and internal TLS.

## Design decisions

- **OpenBao, not Vault** — covers every engine we need (SSH CA, KV, dynamic Postgres
  creds, transit, PKI) under an OSI license. Vault only if you later need an engine
  OpenBao dropped in its fork.
- **On a dedicated host, NOT in k8s** — a secrets/CA root-of-trust must outlive the
  cluster it serves (no circular dependency) and sit outside its blast radius.
  `k8s-auth` still reaches back into the cluster for in-cluster workloads.
- **Tailscale + LAN only, never the Cloudflare tunnel** — machine clients authenticate
  with tokens/JWTs (not browser SSO), and the recovery service must not depend on an
  external SaaS to be reachable. Pods use the LAN IP; humans + the laptop agent use
  Tailscale.
- **Integrated Raft storage** — no external DB.

## Layout

```
ansible/
  create-bao-vm.yml            # create the host as a tiny libvirt VM (cloud-init)
  provision-openbao.yml        # deploy play (install + Raft + TLS + systemd)
  tpm-seal.yml                 # one-way: pkcs11 seal key → YubiKey escrow + bao1's TPM
  inventory/hosts.yml          # the bao host (LAN IP)
  group_vars/all/vars.yml      # version/checksum, addresses, firewall, auto-unseal
  group_vars/all/vault.example.yml
  roles/bao_vm/                # 1 vCPU / 1 GB / 10 GB Ubuntu VM on br0 (ZFS zvol)
  roles/openbao/               # install, TLS bootstrap cert, config, systemd unit
```

`provision-openbao.yml` **only deploys the daemon**. It does not initialize, unseal, or
configure any secrets engines/auth methods — that is a separate bootstrap play (later).

```
terraform/                     # OpenBao's API-level CONFIGURATION (see below)
  mounts.tf  pki.tf  ssh.tf  auth.tf  policies.tf
  auth-spire.tf                # SPIFFE JWT-SVID -> short-lived Bao tokens
  imports.tf                   # adopts the already-running instance into state
  policies/*.hcl               # policy bodies, kept diffable
```

## Ownership: Terraform vs Ansible

**Terraform manages OpenBao itself. Ansible manages the machine under it, plus the
few things Terraform must not own.**

| Terraform (`terraform/`) | Ansible (`ansible/`) |
|---|---|
| secrets engine mounts (`kv`, `pki`, `ssh-client-signer`) | the daemon, Raft, TLS files, systemd |
| PKI role, issuing/CRL URLs, cluster paths, **ACME** | `bao operator init` / unseal (manual, PGP-wrapped) |
| SSH signing role (`ai-agent`) | **PKI root CA + SSH CA signing key** |
| Kubernetes auth mount 与 role（人员登录 `auth/oidc-sso` 在 `apps/iam-login/terraform`） | |
| all policies | snapshot token + script + systemd timer |
|  | host-level CA trust distribution (`openbao_ssh_ca_trust`) |

Why the exceptions stay in Ansible:

- **Root-of-trust key material** (PKI root CA, SSH CA signing key). A Terraform
  resource treats drift as *regenerate*, which would silently invalidate every
  issued certificate and every `TrustedUserCAKeys` line on every host. Generated
  once, never reconciled.
- **The OIDC client secret.** Terraform cannot read it back from the API, so
  managing it would put the plaintext into `terraform.tfstate` **and** produce a
  permanent diff. It lives in `group_vars/all/vault.yml` (ansible-vault).
- **Snapshot token + timer.** A systemd unit on a host, and a token that would
  otherwise land in state.

The switch is `openbao_config_managed_by_terraform` (default `true`) in
`roles/openbao_bootstrap/defaults/main.yml`. It gates every task Terraform now
owns. Set it `false` only to bootstrap without Terraform — leaving it `false`
against a Terraform-managed instance makes the two overwrite each other on
alternate runs.

**Fresh-install order** (the one ordering constraint this split creates — CA
material needs its mount to exist first):

1. `ansible-playbook provision-openbao.yml` — daemon, TLS, systemd
2. `bao operator init` + unseal — manual, PGP-wrapped to the YubiKey
3. `terraform apply` — mounts, roles, policies, ACME
4. `ansible-playbook bootstrap-openbao.yml` — root CA, SSH CA key, OIDC secret, snapshots

For the **existing** instance, `terraform/imports.tf` adopts what is already
running; the plan must read *"N to import, 0 to destroy"*. A proposed destroy or
replace of `vault_mount.pki` would take the root CA with it — fix the HCL, never
apply through it.

Terraform authenticates from the ambient CLI session (`bao login -method=oidc`,
then `VAULT_ADDR`/`VAULT_TOKEN`), mirroring how `smtp-relay/terraform` uses
`az login`. It targets OpenBao via the **`hashicorp/vault`** provider, because the
native `openbao/openbao` provider is published only to the OpenTofu registry and
cannot be resolved by the HashiCorp `terraform` CLI.

Sandbox 集群使用独立的 `auth/kubernetes-sandbox`。其 API 地址、公开 Kubernetes CA、
ESO role 与只读 `kv/k8s/opensandbox-api` policy 全部由 Terraform 管理；CA 位于
`terraform/certs/sandbox-kubernetes-ca.crt`。集群重建并轮换 CA 后，先更新该文件并
apply，再让 Flux 恢复 ESO reconciliation。该 backend 不保存 reviewer JWT，而是使用
ESO 的短期登录 JWT 执行 TokenReview。该组资源已于 2026-09-18 apply，随后复验 plan
为 zero-diff。

## DNS

`bao.lab.ddupan.top` is the name clients use; its A record is in
`../dns/terraform/hosts.tf` (PowerDNS, `lab.ddupan.top`). The original
`bao.ad.ddupan.top` stays: already-issued certs carry it in their AIA/CRL URLs and the
ACME accounts are bound to it. Both are **internal-only** — not public Cloudflare records
and not behind the tunnel. The ad record lives on the Samba DC (authoritative for
`ad.ddupan.top`), same pattern as the KMS record:

```bash
# on the DC, or with -U administrator%<pass>:
samba-tool dns add 192.168.10.5 ad.ddupan.top bao A 192.168.10.8 -U administrator
```

For remote/off-LAN clients, resolution rides your existing setup: the DC (`192.168.10.5`)
is reachable over the tailnet via the `192.168.10.0/24` subnet route, so point
`ad.ddupan.top` at it in Tailscale **split-DNS** (as you already do for other internal
names). LAN clients that use the DC as resolver get it directly.

## Create the host

A dedicated minimal VM — NOT on the DC or the k8s host — keeps the root-of-trust out of
the blast radius of what it protects. bao is tiny, so this costs almost nothing.

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
# set openbao_lan_ip in group_vars/all/vars.yml (also the VM's static IP)
ansible-playbook create-bao-vm.yml           # runs on the libvirt host (localhost)
```

## Deploy

```bash
# inventory/hosts.yml bao1 IP must match openbao_lan_ip
ansible-playbook provision-openbao.yml --ask-vault-pass
ansible-playbook provision-openbao.yml --tags verify      # smoke tests
```

After the first run the node is **uninitialized + sealed** — expected.

## Initialize (once, by hand — PGP-wrapped to your YubiKey)

Encrypt the unseal keys + root token to your YubiKey's GPG public key so they are
never printed in plaintext. Add a **backup offline GPG key** as a second share so a
lost/dead YubiKey doesn't make the data unrecoverable.

```bash
gpg --export <YUBIKEY_KEYID> | base64 > yubikey.pub.b64
gpg --export <BACKUP_KEYID>  | base64 > backup.pub.b64

BAO_ADDR=https://127.0.0.1:8200 BAO_SKIP_VERIFY=true \
  bao operator init -key-shares=2 -key-threshold=1 \
    -pgp-keys="yubikey.pub.b64,backup.pub.b64" \
    -root-token-pgp-key="yubikey.pub.b64"

# Commit both as ciphertext, like .vault_pass.gpg — the runbooks below read them:
echo "<Unseal Key 1 from the output>"       | base64 -d > unseal-key.gpg
echo "<Initial Root Token from the output>" | base64 -d > root-token.gpg
```

With transit auto-unseal (`openbao_auto_unseal: true`) there are no unseal keys — use
`-recovery-pgp-keys` instead, and unsealing becomes automatic on restart.

## Unseal after a restart

**bao1 auto-unseals from its TPM since 2026-11-05** (see "TPM seal"); restarts of the service,
the VM or the laptop need nothing. This section is for when it stays sealed anyway
(TPM replaced or cleared) and for a Shamir node. On the machine
the YubiKey is plugged into (not over ssh into the laptop — the forwarded agent cannot decrypt):

```bash
infrastructure/openbao/unseal.sh        # touch the YubiKey → prints "unsealed"
```

On Windows (Gpg4win's `gpg.exe` in PATH — not Git for Windows' gpg, which cannot see the card):

```powershell
powershell -ExecutionPolicy Bypass -File infrastructure\openbao\unseal.ps1
```

It reads `unseal-key.gpg` (ciphertext, encrypted to `0166F47B5400ECC2`), checks the seal
status first, and sends the key over stdin. Until bao is unsealed, External Secrets cannot
sync, CI cannot log in, and pods that fetch the internal CA at start (dynamic-runner) wait.

## TPM seal (pkcs11 auto-unseal)

Goal: a laptop reboot no longer needs the YubiKey. bao1 has the laptop's TPM 2.0 passed
through (`bao_vm_tpm_passthrough`). The seal is OpenBao's `pkcs11` KMS plugin over
tpm2-pkcs11, with an RSA-2048 key that is **imported, not generated in the TPM**:

- Raft stores ONE seal-wrapped root key, so every node (and every `raft join`) needs the
  SAME seal key. The YubiKey escrow `tpm-seal-key.gpg` is how a new node or a replacement
  TPM gets it, and it keeps the YubiKey as the root of trust (CLAUDE.md "Rebuild order").
- With auto-unseal the Shamir key becomes a **recovery key: it can no longer decrypt
  anything**. Losing the TPM AND the escrow means losing the data.
- Only one seal is active. The phone (teekms) was the alternative; it adds a device, WiFi
  and custom code to the unseal path of a single-node bao for no security gain.
- The unit runs with `PrivateDevices=no` while the seal is on (a private `/dev` has no TPM).
- Re-encrypt `tpm-seal-key.gpg` when the [E] subkey is rotated (expires 2027-04-07).

**Staging (no restart):** mint the key, escrow it, import it, and check the escrow:

```bash
cd infrastructure/openbao/ansible
ansible-playbook tpm-seal.yml          # writes ../tpm-seal-key.gpg + ../tpm-seal.pub; commit both
# on the YubiKey machine, from infrastructure/openbao (touch the key):
gpg -dq tpm-seal-key.gpg | openssl pkey -pubout | cmp - tpm-seal.pub && echo ESCROW OK
```

**Migration (change window; bao restarts three times):**

1. Take a Raft snapshot off-box (`bao operator raft snapshot save`).
2. Upgrade on its own first, so a failure has one cause: `provision-openbao.yml` with the
   seal still off → restart → `../unseal.sh`. Before that, check `bao auth list` /
   `bao secrets list` for `ldap`, `kerberos` or `radius`: 2.7 dropped them from the binary.
3. Set `openbao_pkcs11_seal: true` in `group_vars/all/vars.yml`, then
   `ansible-playbook provision-openbao.yml --check --diff` and apply. bao restarts sealed;
   `seal-status` shows `"migration":true`.
4. `MIGRATE=1 ../unseal.sh` (YubiKey) → `unsealed`, and `seal-status` reports `"type":"pkcs11"`.
5. `sudo systemctl restart openbao` on bao1 → it must come back unsealed by itself. Then
   cold-boot bao1 (`virsh shutdown`/`start`) for the real test.

**Rollback to Shamir:** set `openbao_pkcs11_seal_disabled: true`, apply, then
`MIGRATE=1 ../unseal.sh` (the old Shamir key is now the recovery key). Afterwards set both
`openbao_pkcs11_seal*` back to false and apply; the node is plain Shamir again.

**Recovery (TPM replaced, or a new node):** the old store is useless off its TPM.

```bash
# bao1
sudo systemctl stop openbao
sudo mv /opt/openbao/tpm2-pkcs11 /opt/openbao/tpm2-pkcs11.dead
# YubiKey machine, from infrastructure/openbao (the PEM lands on bao1's tmpfs only)
gpg -dq tpm-seal-key.gpg | ssh ansible@192.168.10.8 'sudo install -m 0600 /dev/stdin /run/tpm-seal.pem'
cd ansible && ansible-playbook tpm-seal.yml -e openbao_pkcs11_import_key=/run/tpm-seal.pem
# checks the key against tpm-seal.pub, imports it under a fresh PIN, shreds the PEM;
# then provision-openbao.yml (renders the new PIN and restarts bao → unsealed)
```

**Restore drill:** rebuilds bao from the repo in a throwaway VM and restores the newest off-site
snapshot, without touching bao1. On a machine with the YubiKey, run `./restore-drill.sh` (Linux,
macOS) or `restore-drill.ps1` (Windows). It runs `provision-openbao.yml` and `tpm-seal.yml` against
an Incus VM with a vTPM on the laptop (`inventory/drill.yml`), removes the VM's NIC before the
snapshot arrives (a restored bao holds real leases and would try to revoke them), restores, checks
that it unseals by itself after a restart, gets a token with the recovery key, prints names and
counts only, and deletes the VM.

**Using the recovery key on a real node:** set `openbao_disable_unauthed_generate_root: false` and
run `provision-openbao.yml` (restarts bao); set it back afterwards.

**Upgrades:** Renovate bumps `openbao_pkcs11_plugin_release` and `openbao_pkcs11_plugin_binary_release`
together, each with its sha256 re-pinned from the release's checksums file (tarball for the download,
binary for the `sha256sum` bao re-verifies before exec); the role asserts the two tags are equal.

## Bootstrap (engines, auth, policies)

Once initialized + unsealed, configure the bao side. Authenticate with the root token
(decrypt it, then export), and run the bootstrap play:

```bash
export BAO_TOKEN="$(gpg -dq ../root-token.gpg)"   # touch YubiKey; ciphertext committed
ansible-playbook bootstrap-openbao.yml --ask-vault-pass
ansible-playbook bootstrap-openbao.yml --tags verify
```

It enables **KV v2**, the **SSH CA** (`ssh-client-signer` + `ai-agent` role), **PKI**,
the **ai-agent-ssh** policy, and a **Raft snapshot** timer. Human OIDC login (`auth/oidc-sso`, iam-login →
`admin` policy for the `platform-admins` AD group) is configured by `apps/iam-login/terraform`, which creates its
client secret; after a rebuild, use the root token until that root has applied.
Idempotent — safe to re-run. Selective runs via tags: `kv,ssh_ca,pki,k8s,policies,snapshots`.
Debug a step with `-e openbao_no_log=false`.

Off by default (need extra inputs, enable when ready):
- **Kubernetes auth** — `openbao_enable_k8s_auth: true` + reviewer JWT/CA (for in-cluster agents like hermes).
- **PKI listener cert** — `openbao_pki_replace_listener_cert: true` swaps the self-signed
  cert for a PKI-issued one (clients must then trust the PKI root CA; a Shamir node
  re-seals on the restart).

Afterwards, create a scoped admin path (OIDC login) and **revoke the root token**:
`bao token revoke -self`.

## Publicly-trusted TLS (ACME DNS-01)

Replace the self-signed listener cert with a **Let's Encrypt** cert so clients drop
`BAO_SKIP_VERIFY`. `ad.ddupan.top` is split-horizon — the DC serves it internally, but
it is **not delegated** in public DNS, so Cloudflare answers `*.ad.ddupan.top`
authoritatively. lego writes a **transient** `_acme-challenge.bao.ad.ddupan.top` TXT into
the Cloudflare `ddupan.top` zone, LE validates, and issues for the **internal** name —
no permanent record, no IP leak. `bao.lab.ddupan.top` is a second SAN on the same cert
(`openbao_acme_extra_domains`), validated the same way; lab is not publicly delegated either. Renewal reloads bao via **SIGHUP** (no restart/reseal).

By default it **reuses the Cloudflare token already managed for the tunnel**
(`cloudflared/terraform/terraform.tfvars` — it has `Zone:DNS:Edit` on ddupan.top), so
there's nothing new to store. To use a dedicated least-privilege token instead, set
`vault_openbao_cf_dns_token` in `vault.yml`.

```bash
ansible-playbook acme-openbao.yml --ask-vault-pass
```

Test against LE **staging** first to avoid rate limits: set `openbao_acme_server:
https://acme-staging-v02.api.letsencrypt.org/directory`, run, confirm, then clear it and
re-run for a real cert (`rm -rf /etc/openbao/acme` on the host between the two to reset).

Note: the LE cert covers the **hostnames only** (`bao.ad.ddupan.top`, `bao.lab.ddupan.top`),
not the IP — so after this, use `BAO_ADDR=https://bao.lab.ddupan.top:8200` (no
skip-verify), not the IP.

## Using it

Kubernetes workload 不接收长期 `BAO_TOKEN`：它通过 SPIRE Workload API 获取
JWT-SVID，再经 `auth/jwt-spire/login` 换取短期、最小权限 token。完整接入流程、
manifest、exchange 脚本、安全要求和排障方法见
[`../../platform/spire/RUNBOOK.md`](../../platform/spire/RUNBOOK.md)。

```bash
# human: log in via iam-login (password + passkey)
bao login -method=oidc -path=oidc-sso   # browser → sso.ddupan.top

# agent: mint a 5-min SSH cert for a target, then connect
ssh-keygen -t ed25519 -f /run/agent/id -N ''
bao write -field=signed_key ssh-client-signer/sign/ai-agent \
  public_key=@/run/agent/id.pub valid_principals=<node> > /run/agent/id-cert.pub
ssh -i /run/agent/id <user>@<node>
```

Each no-root target trusts the CA via one line in `~/.ssh/authorized_keys` (the play
prints it): `cert-authority,principals="<node>",restrict,pty <ca-pubkey>`.

## Operational notes

- **Restarts auto-unseal** via the TPM (bao1 migrated 2026-11-05). Sealed after a restart
  means the TPM side failed: `journalctl -u openbao` (pkcs#11 Login errors), then "TPM seal"
  recovery. `unseal-key.gpg` is now the **recovery** key (`generate-root`, rollback), not an unseal key.
- **Raft snapshots** run daily on bao1 (7 kept locally). Each is GPG-encrypted to the YubiKey and
  uploaded to the OCI bucket `bao-snapshot`, kept 7 days. bao1's key can only create objects. To get
  one back, as an OCI admin on a machine with the YubiKey:
  `oci os object get -bn bao-snapshot --name <object> --file s.snap.gpg && gpg -d -o s.snap s.snap.gpg`.
  Restoring it also needs the seal key: see "TPM seal" recovery.
- The listener uses a **self-signed bootstrap cert**; replace it with a cert issued by
  OpenBao's own PKI engine in the bootstrap play.
