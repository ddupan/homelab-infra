# Renovate

Hourly CronJob running self-hosted Renovate against Gitea as the restricted user
`renovate-bot`. Global config: `config.js`; per-repo rules: each repo's `renovate.json`
(repos without one get an onboarding PR first).

**Scope = renovate-bot's collaborator list.** A restricted Gitea user sees only repos it was
explicitly added to, so adding/removing a repo is a collaborator change in Gitea, not a
config change. `autodiscoverFilter` additionally excludes Ayatori, whose code we never touch.

PRs are never auto-merged: IaC goes through review like any other change, and every PR
costs a CI run on the laptop (hence `prHourlyLimit`/`prConcurrentLimit`).

## Bootstrap (once)

```bash
# 1. Account. Password login is disabled site-wide, so the random password is never used.
kubectl -n gitea exec deploy/gitea -c gitea -- gitea admin user create \
  --username renovate-bot --fullname 'Renovate Bot' \
  --email renovate-bot@users.noreply.ddupan.top \
  --random-password --random-password-length 40 --must-change-password=false --restricted >/dev/null

# 2. Token straight into Bao — never echoed. Scopes per Renovate's Gitea platform docs.
kubectl -n gitea exec deploy/gitea -c gitea -- gitea admin user generate-access-token \
  --username renovate-bot --token-name renovate --raw \
  --scopes write:repository,write:issue,read:user,read:organization \
  | tr -d '\n' | bao kv put kv/k8s/renovate token=-   # --raw ends with a newline; `token=-` would keep it

# 3. Scope: write collaborator on each repo it should manage (never ayatori).
for r in homelab-infra homelab-cookbooks iam-login ...; do
  tea api -X PUT "/repos/panxiao81/$r/collaborators/renovate-bot" -d '{"permission":"write"}'
done
```

Trigger a run without waiting: `kubectl -n renovate create job --from=cronjob/renovate renovate-manual`.
