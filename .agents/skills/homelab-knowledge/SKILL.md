---
name: homelab-knowledge
description: Query and maintain the shared homelab-wiki when working on homelab services, infrastructure, architecture, operations, or current service status. Use it to gather existing context before work and to keep durable knowledge synchronized after relevant changes; do not use it for unrelated software work or as a substitute for commit and PR history.
---

# Homelab Knowledge

Use `homelab-wiki` as the shared long-lived knowledge base for people and agents. Search it directly with `rg`; do not introduce a search index, vector database, or generated copy of the wiki.

## Locate the wiki

Resolve the checkout in this order:

1. `$HOMELAB_WIKI_PATH`, when set.
2. A sibling directory named `homelab-wiki` next to the current repository.
3. `/home/panxiao81/homelab-wiki` when it exists.

If no checkout is available, report that constraint. Do not silently skip the knowledge step, clone a repository, or create a replacement wiki without the user's authorization.

Before using the wiki, read its `AGENTS.md` completely. For edits, also read `README.md` and `CONTRIBUTING.md` completely and follow any more specific instructions associated with the target page.

## Gather context

At the beginning of a homelab task:

1. Derive search terms from the component name, service aliases, hostnames, Kubernetes resources, configuration keys, error text, and task intent.
2. Use `rg -n -i` in the wiki to find candidate pages. Prefer several precise searches over reading the whole repository.
3. Follow the wiki's task index, service index, architecture constraints, source records, and verification conflicts when they are relevant.
4. Read the closest authoritative pages and their material links before making decisions. Also read the corresponding source repository README or runbook when changing an implementation.
5. Distinguish documented design, declared configuration, deployment history, live verification, and work currently in progress. Do not present one as another.

For questions about current project or service status, first obtain the maintainer's current-work and ticket context as required by the wiki, unless the conversation already provides that authorization and scope. Reading documentation does not authorize live-system inspection.

Answer read-only questions from the evidence found. Include paths or links that let the user verify important claims, and state when evidence may be stale or conflicting.

## Maintain knowledge after changes

For any code, configuration, infrastructure, or operational change, perform a documentation-impact check before declaring the task complete.

Update the wiki in the same task when the change affects durable knowledge such as:

- service purpose, lifecycle, entry point, authentication, permissions, dependencies, or first-use path;
- architecture boundaries or accepted constraints;
- deployment ownership or persistent operating behavior;
- troubleshooting, recovery, verification, or maintenance procedures;
- the addition, replacement, or retirement of a service.

Keep one-time progress, implementation narration, and release-by-release history in commits, PRs, or tickets. Do not copy them into the wiki unless they change a durable stage summary. Implementation-specific parameters may remain in the source repository README or runbook when the wiki convention says to link rather than duplicate them.

When editing:

1. Inspect both the source-repository diff and the wiki working tree before writing. Preserve unrelated user changes in both repositories.
2. Update the page closest to the fact first, then only the navigation, indexes, constraints, or verification records that the wiki rules require.
3. Preserve evidence metadata. Never advance `last_verified` without performing the stated live verification; ordinary review may update only fields permitted by the wiki.
4. Link related source commits, PRs, or paths when available. Clearly mark uncommitted sources and unfinished cross-repository synchronization.
5. Record conflicts rather than resolving them by assumption. Ask before live inspection or before choosing among materially conflicting current-state claims.
6. Keep credentials, tokens, private keys, Terraform state, secret values, and sensitive command output out of documentation. Never read or copy known sensitive files merely to improve the wiki.

Wiki edits are a separate repository change. Do not commit, push, open a PR, or modify a live system unless the user has authorized that action.

## Verify and report

After editing the wiki, run from its root:

```bash
python3 scripts/check_docs.py
git diff --check
```

If the checker itself changed, also run:

```bash
python3 -m unittest discover -s tests -v
```

In the final response, report source-repository changes and wiki changes separately, including validation performed and anything still awaiting verification or cross-repository linkage. If no wiki update was needed, state the concrete reason; do not merely say that documentation was unaffected.
