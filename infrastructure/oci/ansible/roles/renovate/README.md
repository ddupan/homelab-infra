# Renovate

Self-hosted Renovate against Gitea as the restricted user `renovate-bot`, run hourly (`:17`) on
oci-arm by `renovate.timer` (`renovate.yml`). It used to be a CronJob on the laptop k3s and moved off
it for memory (#642). Global config: `files/config.js`; per-repo rules: each repo's `renovate.json`
(repos without one get an onboarding PR first).

**Credentials come from SPIFFE, nothing is stored on the host.** Before each run the dedicated user
`renovate` (uid 12021, not in the docker group) fetches a JWT-SVID from the local spire-agent
(`spiffe://ddupan.top/node/oci-arm/renovate`, `platform/spire/oci-arm.yaml`), logs in to Bao's
`jwt-spire` role `renovate`, reads `kv/k8s/renovate`, and revokes the token (`files/renovate-env`).
The tokens sit in `/run/renovate/env` (tmpfs, root, 0600) for the run only. If the WAN is down the
login fails and that hour is skipped; the next one catches up.

**Scope = renovate-bot's collaborator list.** A restricted Gitea user sees only repos it was
explicitly added to, so adding/removing a repo is a collaborator change in Gitea, not a
config change.

PRs are never auto-merged: IaC goes through review like any other change, and every PR
costs a CI run on the laptop (hence `prHourlyLimit`/`prConcurrentLimit`).

## Bootstrap (once)

```bash
# 1. Account. Password login is disabled site-wide, so the random password is never used.
ssh oci-arm sudo docker exec -u git gitea-gitea-1 gitea admin user create \
  --username renovate-bot --fullname 'Renovate Bot' \
  --email renovate-bot@users.noreply.ddupan.top \
  --random-password --random-password-length 40 --must-change-password=false --restricted >/dev/null

# 2. Token straight into Bao — never echoed. Scopes per Renovate's Gitea platform docs.
#    pipefail: without it a failed generate still writes an EMPTY token to Bao.
set -o pipefail
ssh oci-arm sudo docker exec -u git gitea-gitea-1 gitea admin user generate-access-token \
  --username renovate-bot --token-name renovate --raw \
  --scopes write:repository,write:issue,read:user,read:organization \
  | tr -d '\n' | bao kv put kv/k8s/renovate token=-   # --raw ends with a newline; `token=-` would keep it

# 3. Scope: write collaborator on each repo it should manage.
for r in homelab-infra homelab-cookbooks iam-login ayatori ...; do
  tea api -X PUT "/repos/panxiao81/$r/collaborators/renovate-bot" -d '{"permission":"write"}'
done

# 4. GitHub read-only token (fine-grained, public repos, no permissions), typed not echoed:
read -rsp 'GitHub token: ' t && [ -n "$t" ] && printf %s "$t" | bao kv patch kv/k8s/renovate github_com_token=-
```

Trigger a run without waiting: `sudo systemctl start --no-block renovate` on oci-arm. A oneshot unit
already running is not started twice, so this cannot race the timer. Logs: `journalctl -u renovate`.
