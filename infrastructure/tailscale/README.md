# Tailscale（tailnet 配置）

`terraform/` 管 tailnet 的 policy file、split DNS 和 GitHub Actions 用的 federated identity。
2026-11-27 之前这些都在 admin console 里手改；从这里接管后，console 里的改动会被 main 的下一次 apply 回滚。

不管的：设备本身（登录、key expiry，laptop 与 homelab-vm 已关闭 expiry）、subnet route 的通告
（`apps/tailscale/subnet-routes.sh`，laptop 上 `tailscale set`）。route 的**批准**交给 policy 的
`autoApprovers`，不逐台写 Terraform。

## 凭据

代码和 Bao 里都没有 Tailscale 凭据。CI 中 provider 自己用 job 的 GitHub OIDC token 换 API token：
PR 的 plan 用只读身份（`all:read`），main 的 apply 用可写身份；两者以及 runner 入网用的 `tag:ci`
身份都在 `main.tf` 里定义，client ID 与 audience 不是机密，放 homelab-infra 的仓库变量
（`terraform output github_variables`）。

## 本地运行 / 首次接管 / 被锁在外面时

用一次性的 API access token（admin console → Settings → Keys，设短有效期，用完撤销）：

```sh
# Bao token：本机 SPIRE 登录（local-development 能读 tfstate 的 S3 凭据）
export TAILSCALE_API_KEY=…
uv run .github/scripts/tf.py run infrastructure/tailscale/terraform init
uv run .github/scripts/tf.py run infrastructure/tailscale/terraform import tailscale_acl.policy acl
# split DNS：每个域名 import 一次
uv run .github/scripts/tf.py run infrastructure/tailscale/terraform import 'tailscale_dns_split_nameservers.this["lab.ddupan.top"]' lab.ddupan.top
uv run .github/scripts/tf.py run infrastructure/tailscale/terraform apply
```

CI 的身份或 `tag:ci` 规则被改坏时，同样用这条本地路径修复。
