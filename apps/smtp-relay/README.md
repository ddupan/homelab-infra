# SMTP relay (Postfix + sasl-xoauth2 → Microsoft 365)

One internal SMTP endpoint that in-cluster apps use for outbound mail. It authenticates
to Exchange Online with **OAuth2 (XOAUTH2)** via [`mauroreggio/postfix-365`], which bundles
[`sasl-xoauth2`] — tokens are refreshed **inside the SASL layer**, no sidecar/cron. Basic-auth
SMTP (app passwords) is being retired by Microsoft; this is the modern replacement.

```
Authelia / Gitea / … ──plain SMTP :25 (in-cluster, no auth)──▶ smtp-relay ──587 STARTTLS + XOAUTH2──▶ smtp.office365.com
```

Reach it at: `smtp-relay.smtp-relay.svc.cluster.local:25`. Sends **as** `noreply@ddupan.top`.

[`mauroreggio/postfix-365`]: https://github.com/mauroreggio/postfix-365
[`sasl-xoauth2`]: https://github.com/tarickb/sasl-xoauth2

---

## Prerequisites (Microsoft 365 / Entra — mostly interactive, one-time)

1. **`ddupan.top` is a verified domain** in the tenant (Admin center → Settings → Domains,
   Status = Healthy). If not, add it and complete the TXT verification (DNS is Cloudflare —
   can be done in `../../../infrastructure/cloudflared/terraform/`).
2. **Mailbox `noreply@ddupan.top`** exists with an **Exchange Online license**.
3. **Authenticated SMTP enabled** on it: Admin center → Users → that user → Mail →
   *Manage email apps* → tick **Authenticated SMTP**. (OAuth won't work without this.)

## Step 1 — Entra app registration (as code)

```bash
cd terraform
az login          # account that can create app regs AND grant admin consent (Global Admin)
terraform init
terraform apply   # creates the app, delegated Graph SMTP.Send + admin consent, a client secret
```

Grab the three values for the k8s secret:

```bash
terraform output -raw client_id
terraform output -raw tenant_id
```

> This is a **PUBLIC** client (device-code flow) — there is **no client secret**. Leave
> `CLIENT_SECRET` empty in `secret.yaml`. Presenting a secret makes Entra reject the token
> refresh with `AADSTS700025 "Client is public..."`.

## Step 2 — Deploy the relay

```bash
cd ..
cp secret.example.yaml secret.yaml      # paste CLIENT_ID / CLIENT_SECRET / TENANT_ID
kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml -f pvc.yaml
kubectl apply -f deployment.yaml -f service.yaml
kubectl -n smtp-relay rollout status deploy/smtp-relay
```

At this point Postfix runs but has **no token yet**, so relaying fails until step 3.

## Step 3 — Bootstrap the token (one-time, interactive device-code)

The image's `sasl-xoauth2-tool` needs the `msal` Python module, which isn't bundled.
Install it ephemerally (only needed for this one mint; the C++ SASL plugin refreshes
without it):

```bash
POD=$(kubectl get pod -n smtp-relay -l app=smtp-relay -o name | head -1 | cut -d/ -f2)
kubectl exec -n smtp-relay $POD -- sh -c 'python3 -m ensurepip >/dev/null 2>&1; python3 -m pip install -q msal'
```

Mint the token (env vars come from the pod's secret; `CLIENT_SECRET` is empty → public flow):

```bash
kubectl exec -n smtp-relay -it deploy/smtp-relay -- sh -c \
  'sasl-xoauth2-tool get-token outlook /etc/tokens/noreply@ddupan.top \
     --client-id="$CLIENT_ID" --tenant="$TENANT_ID" --client-secret="$CLIENT_SECRET" --use-device-flow'
```

It prints a URL + code — open <https://microsoft.com/devicelogin> and **sign in as the SENDER
mailbox `noreply@ddupan.top`** (NOT yourself/the admin — a token minted for the wrong user gives
`535 5.7.3`). If prompted for a client secret, press Enter. Then fix ownership so Postfix can
read/rewrite it:

```bash
kubectl exec -n smtp-relay $POD -- chown postfix:postfix /etc/tokens/noreply@ddupan.top
```

Verify identity if unsure: decode the token and check `upn` == `noreply@ddupan.top`. The token
persists on the PVC; sasl-xoauth2 refreshes it automatically thereafter.

## Step 4 — Test

```bash
kubectl exec -n smtp-relay $POD -- sh -c \
  'echo "Subject: relay test\n\nhello" | sendmail -f noreply@ddupan.top you@example.com'
kubectl exec -n smtp-relay $POD -- tail -n 40 /var/log/maillog   # look for "status=sent"
```

## Step 5 — Point apps at it

- **Authelia** — replace the filesystem notifier with SMTP in `../authelia/values.yaml`:
  address `smtp://smtp-relay.smtp-relay.svc.cluster.local:25`, sender `noreply@ddupan.top`,
  `disable_require_tls: true` (plain in-cluster hop). 2FA enrollment codes then go to real email.
- Any future app: same address, **From = `noreply@ddupan.top`** (O365 rejects other senders
  with `5.7.60` unless a send-as alias is configured in Exchange).

## Deliverability (keep mail out of Junk)

- **SPF / MX / DMARC** for `ddupan.top` already exist (M365 domain setup).
- **DKIM**: ✅ **enabled 2026-07-28** (`Enabled: True`, `Status: Valid`). CNAMEs are in
  `../../infrastructure/cloudflared/terraform/` (`selector1/2._domainkey`); signing was turned on with
  `scripts/enable-dkim.ps1` then `scripts/enable-dkim-finish.ps1`.
  - ⚠️ **The CNAME target is NXDOMAIN until signing is enabled.** Microsoft creates the
    tenant host (`<tenant>.d-v1.dkim.mail.microsoft`) only at enable time, so a correct
    CNAME looks broken beforehand and `Get-DkimSigningConfig` reports `CnameMissing`.
    **Do not go hunting for the "real" CNAME value** — run step 2 and re-check DNS.
  - ⚠️ **Both scripts deadlock if run via `!` or with output redirected to a file** — the
    device code never becomes visible. Run under a PTY:
    `DOTNET_SYSTEM_NET_DISABLEIPV6=1 script -qfc "pwsh -NoProfile -File scripts/enable-dkim.ps1" /tmp/dkim.log`
    The `DISABLEIPV6` is required on the laptop — see the IPv6 trap in the root `CLAUDE.md`;
    without it `Connect-ExchangeOnline` hangs in `SYN-SENT` with no output at all.
- **Still soft**: SPF is `~all` and DMARC is `p=none`. Harden to `-all` / `p=quarantine`
  once aggregate reports confirm DKIM passes — not before, or you quarantine your own mail.

## Notes / gotchas

- **PUBLIC client, no secret** — see Step 1. `CLIENT_SECRET` stays empty.
- **Sign in as `noreply@` (the sender), not the admin**, during the Step 3 device login — a
  token minted for the wrong identity fails with `535 5.7.3`.
- **`msal` is ephemeral** — reinstall it in the pod (Step 3) before any re-mint; it's gone after
  a restart but only the one-time mint needs it.
- **Token PVC is writable state, not in Git.** The refresh token rotates; it lives only on
  the PVC. Back it up if you want to avoid re-running step 3.
- **Refresh-token longevity**: Azure AD refresh tokens renew on use but can expire under
  Conditional Access / long idle — if relaying suddenly fails auth, re-run step 3.
