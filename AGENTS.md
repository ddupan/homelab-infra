# Agent Notes

- This workspace is organized into apps/, platform/, infrastructure/, clusters/, and archive/; components remain independently deployable and there is no shared root package.
- `apps/http-echo/` and `archive/traefik/` contain Kubernetes/Gateway API manifests; inspect their parent Gateway references before applying archived or brownfield resources.
- `apps/tailscale/helm.sh` contains live Tailscale OAuth values; do not copy, print, or commit those values anywhere else.
- Preserve the existing README intent in `apps/http-echo/` and `archive/traefik/` when updating manifests.
- 在 homelab 工作中，所有提交到 `git.ddupan.top` 的 commit message、PR、issue
  和项目文档默认优先使用中文。代码标识符、命令、配置键、上游专有名称，以及
  使用英文能避免歧义的技术字段可保留英文。
