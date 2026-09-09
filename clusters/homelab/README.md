# Homelab cluster

This directory will become the Flux reconciliation entrypoint for the homelab
k3s cluster. It is intentionally documentation-only until a Git remote, CI
checks and a low-risk bootstrap workload have been verified.

Planned reconciliation order:

1. namespaces and CRDs;
2. shared platform controllers;
3. secret references and storage;
4. applications.

Do not enable pruning for a path until its live resources and field ownership
have been audited.
