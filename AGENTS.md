# Agent Notes

- This workspace is organized into apps/, platform/, infrastructure/, clusters/, and archive/; components remain independently deployable and there is no shared root package.
- `apps/http-echo/` and `archive/traefik/` contain Kubernetes/Gateway API manifests; inspect their parent Gateway references before applying archived or brownfield resources.
- `apps/tailscale/helm.sh` contains live Tailscale OAuth values; do not copy, print, or commit those values anywhere else.
- Preserve the existing README intent in `apps/http-echo/` and `archive/traefik/` when updating manifests.
