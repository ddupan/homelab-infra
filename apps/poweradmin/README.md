# Poweradmin — UI for PowerDNS

`https://dns.ad.ddupan.top` (moves to `dns.lab.ddupan.top` with the other services).
Web UI for the PowerDNS that serves `lab.ddupan.top` (`../blocky/`, README there).

## How it fits

- **API mode only.** Poweradmin never touches the pdns database. It reads and
  writes through the HTTP API, like Terraform and external-dns do. Its own SQLite
  (PVC) holds only users and zone permissions.
- In k3s on purpose, unlike pdns and Blocky: it is a management plane, so the
  cluster being down costs the UI and never name resolution.

## Who owns which records

Three writers share one zone. Use the UI to **look at everything** and to **add
ad-hoc names**. Do not edit names the other two own:

| writer | owns | an edit in the UI… |
|---|---|---|
| Terraform (`infrastructure/dns/terraform`) | fixed hosts, the zone | is reverted on the next CI apply, and drifts until then |
| external-dns | HTTPRoute hostnames (TXT ownership marker beside each) | is overwritten within about 30 s |
| Poweradmin | anything else | sticks |

Records created in the UI are safe: Terraform only manages the RRsets it declares,
and external-dns deletes only records it holds a TXT marker for.

## Login

- **LDAP against AD** (`ldaps://dc1.ad.ddupan.top`, verified with the bao CA in
  `bao-ca.yaml`). The search filter admits **direct** members of `platform-admins`
  only. That group and the `svc-poweradmin` bind account are in
  `infrastructure/samba-ad/ansible/group_vars/all/vars.yml`.
- **4.4 cannot auto-provision LDAP users (4.5 can).** Each person needs a local
  stub first: log in as `admin`, then Users → Add, give the AD username, tick
  "LDAP authentication", and pick a permission template. From then on they log in
  with their AD password.
- **`admin`** is local and created on first start from `PA_ADMIN_PASSWORD`. It is
  the break-glass login for when the DC is down.
- OIDC replaces LDAP once iam-login is cut over (`PA_OIDC_*`). Existing users and
  permissions carry over.

## Secrets

`kv/k8s/poweradmin` is synced by ESO. Its keys are env var names (see
`external-secret.yaml`). Two values are copies, so rotate them together:

- `PA_PDNS_API_KEY` = `kv/k8s/powerdns` `api_key`, which pdns also reads.
- `PA_LDAP_BIND_PASSWORD` = `vault_poweradmin_bind_password` in the samba-ad
  ansible vault. Re-run `provision-dc.yml --tags accounts` after changing it.

## Deploy order

1. pdns running (`../blocky/`).
2. Secrets in bao and the samba-ad vault (above).
3. `ansible-playbook provision-dc.yml --tags accounts,dns` in
   `infrastructure/samba-ad/ansible`. This creates `svc-poweradmin`, `platform-admins`
   and the `dns.ad.ddupan.top` A record.
4. Merge. Flux deploys `clusters/homelab/apps/poweradmin.yaml`.
