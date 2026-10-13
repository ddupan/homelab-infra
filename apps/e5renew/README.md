# e5renew

应用与 chart 在 [panxiao81/e5renew](https://github.com/panxiao81/e5renew)（`helm/e5renew`）；这里是部署。
入口 `e5renew.ddupan.top`（Cloudflare 隧道，`infrastructure/cloudflared/terraform`）。

- `helmrelease.yaml`：Flux 部署，GitRepository 固定到 chart 的 commit；升级 chart 改这里的 commit。
- `database.yaml`：pg-prod 租户（`clusters/ayatori-prod/e5renew.yaml`）与应用 Secret `e5renew`。
  应用经连接池 6432；迁移 Job（golang-migrate，会话级 advisory lock）直连 5432。
  2026-10-13 自 k3s 内 CNPG 迁入，同时从 helm CLI 改由 Flux 部署。
- `terraform/`：Entra 应用 `e5renew` 的 client secret（应用注册本身是手工建的，Terraform 只管 secret）。

## Entra client secret 轮换

Entra 的 client secret 一定会过期，所以由 Terraform 签发并写入 `kv/k8s/e5renew-azuread`。不在 CI：CI 没有
可用的 Azure 身份（Entra 联合需要公网可达的签发方，而 Cloudflare 免费版不给四级域名发证书）。
每个 secret 有效 365 天，签发 300 天后的下一次 apply 换新——**到期前必须有人在本机跑一次**：

```bash
az login                      # 需是 e5renew 应用注册的所有者
python3 infrastructure/shared-postgresql/run.py --spiffe terraform -chdir=../../../apps/e5renew/terraform plan
python3 infrastructure/shared-postgresql/run.py --spiffe terraform -chdir=../../../apps/e5renew/terraform apply
python3 infrastructure/shared-postgresql/run.py --spiffe terraform -chdir=../../../apps/e5renew/terraform output   # 到期时间
```

（借用 shared-postgresql 的包装器：它经本机 SPIFFE 取短期 Bao token 与 tfstate 的 S3 身份，只传给子进程。）

换新时 Terraform 先建新 secret 再删旧的，所以同一次里要让应用读到新值：

```bash
kubectl -n e5renew annotate externalsecret e5renew force-sync=$(date +%s) --overwrite
kubectl -n e5renew rollout restart deploy/e5renew
```
