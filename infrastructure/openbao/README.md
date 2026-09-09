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
| OIDC auth *mount* and *role* | OIDC **client secret** (`auth/oidc/config`) |
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

## DNS

`bao.ad.ddupan.top` is an **internal-only** name — not a public Cloudflare record and
not behind the tunnel. Add the A record on the Samba DC (authoritative for
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

# unseal (decrypt a share — touch the YubiKey):
echo "<encrypted-key-b64>" | base64 -d | gpg -dq | xargs bao operator unseal
```

With transit auto-unseal (`openbao_auto_unseal: true`) there are no unseal keys — use
`-recovery-pgp-keys` instead, and unsealing becomes automatic on restart.

## Bootstrap (engines, auth, policies)

Once initialized + unsealed, configure the bao side. Authenticate with the root token
(decrypt it, then export), and run the bootstrap play:

```bash
echo "<encrypted-root-token-b64>" | base64 -d | gpg -dq   # touch YubiKey
export BAO_TOKEN=<plaintext-root-token>
ansible-playbook bootstrap-openbao.yml --ask-vault-pass
ansible-playbook bootstrap-openbao.yml --tags verify
```

It enables **KV v2**, the **SSH CA** (`ssh-client-signer` + `ai-agent` role), **PKI**,
**OIDC auth** (the Authelia `openbao` client → `admin` policy for the
`vault-admins` AD group), the **ai-agent-ssh** policy, and a **Raft snapshot** timer.
Idempotent — safe to re-run. Selective runs via tags: `kv,ssh_ca,oidc,pki,k8s,policies,snapshots`.
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
no permanent record, no IP leak. Renewal reloads bao via **SIGHUP** (no restart/reseal).

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

Note: the LE cert covers the **hostname only** (`bao.ad.ddupan.top`), not the IP — so
after this, use `BAO_ADDR=https://bao.ad.ddupan.top:8200` (no skip-verify), not the IP.

## Using it

```bash
# human: log in via Authelia (2FA)
bao login -method=oidc            # browser → auth.ddupan.top

# agent: mint a 5-min SSH cert for a target, then connect
ssh-keygen -t ed25519 -f /run/agent/id -N ''
bao write -field=signed_key ssh-client-signer/sign/ai-agent \
  public_key=@/run/agent/id.pub valid_principals=<node> > /run/agent/id-cert.pub
ssh -i /run/agent/id <user>@<node>
```

Each no-root target trusts the CA via one line in `~/.ssh/authorized_keys` (the play
prints it): `cert-authority,principals="<node>",restrict,pty <ca-pubkey>`.

## Operational notes

- **Restart re-seals** a Shamir node (needs manual unseal). Harmless before first init;
  automatic re-unseal with transit auto-unseal.
- **Back up** Raft snapshots off-box once initialized: `bao operator raft snapshot save`
  (belongs in the bootstrap play — it needs a token).
- The listener uses a **self-signed bootstrap cert**; replace it with a cert issued by
  OpenBao's own PKI engine in the bootstrap play.
