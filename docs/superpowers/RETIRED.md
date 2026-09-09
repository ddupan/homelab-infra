# docs/superpowers — RETIRED 2026-07-28

The `plans/` + `specs/` workflow is no longer used. Its one piece of work is
**done and live**, so nothing here is pending.

**What it covered:** the 2026-04-18 migration of shared PostgreSQL to
CloudNativePG on OpenEBS ZFS —
`specs/2026-04-18-postgresql-cnpg-zfs-migration-design.md` (design) and
`plans/2026-04-18-postgresql-cnpg-zfs-migration.md` (task-by-task plan).

**Outcome: shipped.** `kubectl get cluster -n shared-db` shows
`shared-postgresql`, 1 instance, *"Cluster in healthy state"*, 101 days old, with
`shared-postgresql-1` Running. The authoritative manifests live in
`../../shared-postgresql/` (`cloudnativepg-cluster.yaml`,
`shared-postgresql-service.yaml`, `serviceaccount.yaml`), and the dump/restore
/cutover/rollback runbook is `../../shared-postgresql/migration.md`.

**Why retired:** the format carried agent-workflow scaffolding ("REQUIRED
SUB-SKILL", checkbox task lists) that only ever suited one migration. Design
documents now live directly in `docs/` — see `../cicd.md` — and the split that
matters is:

- `CHANGELOG.md` — what changed, for humans
- `CLAUDE.md` — traps and procedures, for agents
- `docs/*.md` — design docs for work not yet built
- `<service>/README.md` — how a service actually works

The two files are kept for the migration rationale, which is still the best
record of why CNPG and ZFS were chosen. Nothing reads them automatically.
