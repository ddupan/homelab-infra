# vmagent scrape-config hot-reload on k3s

## Symptom
New/changed `VMServiceScrape`/`VMNodeScrape`/`VMStaticScrape`/... are written by the
operator into the `vmagent-main` config Secret, but the running vmagent keeps serving
its **startup** config — the new targets never appear until vmagent is restarted.

## Cause
vmagent's config-reloader (`victoriametrics/operator:config-reloader-*`) watches the
config Secret with a client-go informer, which does `list` **and** `watch`. The
operator-generated Role `monitoring:monitoring:vmagent-main` grants `secrets: [get, watch]`
but **not `list`**, so on k3s the informer errors with:

```
cannot list resource "secrets" in API group "" in the namespace "monitoring"
```

and no reload is ever triggered.

## Fix options

**A) Grant `list` on secrets (proper hot-reload).** Additive, namespace-scoped Role
(vmagent already has get/watch; this adds only `list`). Apply `reload-rbac.yaml`:

```bash
kubectl apply -f metrics/reload-rbac.yaml
```

Marginal exposure: lets the vmagent SA enumerate Secrets in the `monitoring` namespace
only (it can already read them individually). This is what the operator is expected to
grant; the generated Role simply omits `list` on this version.

**B) No RBAC change — restart on change.** Leave RBAC as-is and restart vmagent after
applying scrape-config changes:

```bash
kubectl -n monitoring rollout restart deploy/vmagent-main
```

Fine for a homelab where scrape configs change rarely; the tradeoff is a manual step
(and a ~10s gap) each time.
