# ddupan.top 租户（Entra ID / Microsoft 365）

`ddupan.top` 租户是 Microsoft 365 订阅账号。以后用 Terraform 做的租户变更都放这个 root，每个用途一个文件。
早于本 root 的 `apps/e5renew/terraform` 和 `apps/smtp-relay/terraform` 也动这个租户，目前保持原样。

本地运行，不进 CI：CI 没有可用的 Azure 身份（spire-oidc 只在 LAN 内，Entra 无法与 runner 的 JWT-SVID 联合）。
需要 `az login`（有权管理应用注册的账号）和 tfstate 的 S3 凭据（`kv/k8s/seaweedfs-s3` 的 `terraform`
身份，见 `apps/nexus/README.md`）。

```bash
terraform init
terraform apply
```

## gitea.tf：Gitea 的应急登录源

lab 挂掉时登录 Gitea 的入口：iam-login 依赖 dc1，而 Gitea（oci-arm）本身不在 lab 里。
应用只分配给 `gitea_admin_upn` 一个人（assignment required）；Gitea 按 email 把它关联到已有账号，
所以这个 UPN 的 `mail` 必须是 Gitea 账号的已激活邮箱之一（`panxiao81` 的副邮箱 `panxiao81@ddupan.top`）。

apply 后把 secret 交给 Ansible（不经过终端、不进 Bao——Bao 也在 lab 里）：

1. `tenant_id`、`gitea_client_id` 写进 `infrastructure/oci/ansible/host_vars/oci_arm/gitea.yml` 的
   `gitea_entra_tenant_id` / `gitea_entra_client_id`；
2. `terraform output -raw gitea_client_secret` 写进 `host_vars/oci_arm/vault.yml` 的 `vault_gitea_entra_client_secret`；
3. `ansible-playbook gitea.yml`。登录源只在不存在时创建；**轮换 secret** 时 role 不会更新已有登录源，
   需在 Gitea 管理后台（或 `gitea admin auth update-oauth --id <id> --secret ...`）手工更新。

轮换：`time_rotating` 在首次 apply 后 640 天起的下一次 apply 签发新 secret，每个 secret 有效 730 天。
这是平时没人用的应急入口，过期也不会有人发现——`terraform output gitea_client_secret_expires_at` 记着到期日，
在那之前 apply 一次。
