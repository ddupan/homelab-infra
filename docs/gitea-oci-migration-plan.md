# Gitea → OCI A1 迁移方案（SQLite）

状态：方案，未执行。2026-11-04。

## 为什么

1. **性能**：laptop 长期 load 40–60 / 12 核，Gitea 跟着慢（#580 加 requests 只是缓解）。
2. **恢复路径**：CLAUDE.md 的重建顺序第一步是「repo + YubiKey」，但 repo 现在住在要被重建的
   k3s 里。搬到云上后，lab 全挂时 repo 仍在，恢复不再依赖自身。

目标机 `oci_arm`（`homelab-vm`，A1 2 OCPU / 12 GB / 100 GB，大阪）现在只跑 `outside_watcher`，
load 0.2、空闲内存 9.9 GiB、磁盘空余 92 GB。Gitea 数据约 0.9 GB（actions_artifacts 712 MB、
git 82 MB、attachments 68 MB、actions_log 47 MB），数据库很小。

## 决定

| 项 | 选择 | 理由 |
|---|---|---|
| 运行方式 | Docker Compose，`docker.gitea.com/gitea:<tag>-rootless`，tag 写死 | 单实例不需要 k8s；镜像有 arm64 |
| 数据库 | SQLite（`/data/gitea/gitea.db`） | 数据库只有几十 MB；`gitea dump` 一次就能连同 repo 一起备份，时间点一致。OCI 免费 MySQL 的备份和 repo 不同步，且免费账户只能恢复成另一个免费实例（每个 tenancy 只有一个），不划算 |
| 配置管理 | `infrastructure/oci/ansible/` 新 role `gitea`（照 `outside_watcher` 的样子） | 与看守同一处管理 |
| 秘密 | oci ansible-vault（`host_vars/oci_arm/vault.yml`），**不从 Bao 读** | 恢复根不能依赖 lab 里的 Bao（与 infrastructure/openbao 同理） |
| 公网入口 | A1 公网 IP 443，`git.ddupan.top` 在 Cloudflare 开代理；Gitea 自己用 Cloudflare Origin CA 证书跑 HTTPS（Full strict）；专用 NSG 的 443 只放 Cloudflare IP 段 | 不经 lab 的 tunnel，也不必在 A1 上多跑一个 connector；NSG 限制来源，爬虫无法绕过 zone 级 WAF 规则直连源站。Origin CA 只有 Cloudflare 信任，所以 lab 内也必须经 Cloudflare 访问。私钥只在 vault 里，Terraform 只拿 CSR |
| lab 内访问 | **全部走公网名 `https://git.ddupan.top`**，取消 split-horizon | 见下文「网络」 |
| 登录 | 保留 iam-login 登录源 `sso`（数据库里 ID 3，随数据迁移）；**另加 Entra ID 登录源** | iam-login 依赖 lab 里的 dc1，lab 挂了就无法登录；Entra ID 不依赖 lab，作为第二入口。Entra 应用设成「需要分配用户」，只有被分配的用户能登录，避免 `ENABLE_AUTO_REGISTRATION` 让整个租户都能自动注册；`ACCOUNT_LINKING=auto` 按 email 关联到已有账号。client secret 放 vault。最后兜底仍是 ssh 到 A1 用 `gitea admin` CLI |
| 邮件 | OCI Email Delivery（Always Free 每月 3000 封）SMTP | 集群内的 smtp-relay 从 A1 访问不到，而且它依赖 lab。需要：approved sender `noreply@ddupan.top`、SPF 加 include、DKIM CNAME（都在 Cloudflare，用 Terraform 管理）、SMTP 凭据放 vault |
| 备份 | systemd timer 每天跑 `gitea dump`，以 instance principal 身份 `oci os object put` 到 Object Storage；保留期用 bucket lifecycle 规则 | 磁盘上不放凭据；dump 本身一致 |

**iam-login 不跟着迁。** 它的密码登录、注册和健康检查都要用 LDAPS 连 dc1（在 laptop 上）。
搬到云上后，lab 里每一次登录（Grafana、Bao、Incus……）都要穿过 WAN 绕一圈；WAN 一抖动，
整个 lab 就登不进去。Gitea 只在网页登录时需要它，git 操作和 CI 不受影响。

## 网络

迁移**不依赖**任何私网路径。Flux、runner、Renovate 本来就（或者会改成）使用公网名
`git.ddupan.top`，私网路径也一样要穿过 WAN，换成它只是少经过一次 Cloudflare，对 WAN 抖动的
影响相同。

- 走 Cloudflare 的代价：**请求体上限 100 MB**。现有 repo 总共 82 MB，没有问题；以后如果有大 push
  或大 artifact，再走私网。
- 现状：LAN ↔ `10.0.0.124`（经 VyOS wg42 → oci-amd）已在 #582 修通，RTT 约 4 ms；pod 也能经
  Tailscale 访问 A1。以后如果遇到 100 MB 上限，或者想让 lab 内访问不经 Cloudflare，可以把
  split-horizon 指向 `10.0.0.124`。前提是把源站证书换成公开受信的（如 LE DNS-01），因为 Origin CA
  证书只有 Cloudflare 信任。
- OCI Site-to-Site VPN（IPSec，终结在 DRG，Free Tier 可建 50 条连接）是另一条私网路径，可以替代
  单台 1 GB 的 oci-amd。单独做实验，不阻塞本迁移。

## 步骤

### 0. 准备（可以在旧 Gitea 照常运行时完成）

1. PR：Flux 的三个 GitRepository（`clusters/homelab/flux-system/gotk-sync.yaml`、
   `platform/flux-image-automation/gitrepository.yaml`、`platform/spire/gitrepository-fork.yaml`）
   从 `http://gitea-http.gitea.svc.cluster.local:3000/...` 改成 `https://git.ddupan.top/...`。
   合并后通过 split-horizon 仍然指向旧 Gitea；切换时 Flux 会自动跟过去，不会出现「Flux 要拉取改
   它自己 URL 的那个 commit，却拉不到」的死锁。确认三个 source 都是 Ready。
2. PR：`infrastructure/oci/ansible` 新增 role `gitea`：
   - 安装 docker；Compose 文件里 tag 与 k3s 里的版本一致（当前 `28.3.0`），加 renovate 注释。
   - `app.ini` 照搬 `apps/gitea/gitea-values.yaml` 的 `gitea.config`，`DB_TYPE` 改为 `sqlite3`，
     mailer 指向 OCI Email Delivery。
   - Gitea 在宿主机 443 上跑 HTTPS（Origin CA 证书），来源由 NSG 限制为 Cloudflare。
   - 四个密钥（`SECRET_KEY`、`INTERNAL_TOKEN`、`JWT_SECRET`、`LFS_JWT_SECRET`）照搬 k3s 时期的原值。
     `SECRET_KEY` 加密库内的 2FA 种子和 OAuth secret，换了就解不开。
   - 不带 `[webhook] ALLOWED_HOST_LIST`：k3s app.ini 里那条 dynamic-runner-controller 是 chart
     init 容器只增不删留下的残留，controller 走 runner 协议，不收 webhook。
   - 备份 timer 和 instance principal（dynamic group + policy、bucket + lifecycle 规则放在
     `infrastructure/oci/terraform`）。
3. apply `infrastructure/oci/terraform`（备份 bucket/策略、Gitea NSG）和
   `infrastructure/cloudflared/terraform` 的 `gitea-origin.tf`（只签证书，**不**动 DNS），把证书输出写进
   `host_vars/oci_arm/gitea.yml`。
4. 部署到 A1，用空数据启动，确认 `https://127.0.0.1/api/healthz` 正常。空库无用户，开着也无害；
   切换时再停下导入。
5. 确认 zone 的 SSL 模式是 Full (strict)，或者给 `git.ddupan.top` 单独加一条 Configuration Rule。
   Flexible 会让 Cloudflare 走 80 端口回源，而 NSG 只开了 443。

### 1. 冻结（停机窗口开始）

- 暂停 Renovate CronJob 和 image-automation，把 dynamic-runner controller 缩到 0。这些之外基本
  没有写入来源。
- 改 suspend 时用自定义 `--field-manager`（见 flux-suspend-reverted 记忆），否则会被 Flux 改回去。

### 2. 导出与导入

```bash
# 在旧 Pod 里导出 SQLite 方言的 dump（版本必须与 A1 上一致）
kubectl --context default -n gitea exec deploy/gitea -c gitea -- \
  gitea dump --database sqlite3 --file /tmp/gitea-dump.zip
kubectl --context default -n gitea cp -c gitea <pod>:/tmp/gitea-dump.zip ./gitea-dump.zip
# 然后 scale 旧 Deployment 到 0（HelmRelease 先 suspend）
```

在 A1 上：解压到数据卷（`data/` → `/data`，`repos/` → `/data/git/gitea-repositories`），执行
`sqlite3 /data/gitea/gitea.db < gitea-db.sql`，修正属主（rootless 是 uid 1000），启动，然后
`gitea doctor check --all`。dump 是**明文**（含 token 哈希、OAuth secret），传完立即删除，
不要放进 scratchpad 以外的地方。

### 3. 切换

1. `infrastructure/cloudflared/terraform`：把 `git.ddupan.top` 从 tunnel ingress 列表中移除，同时新增
   指向 A1 公网 IP 的代理 A 记录。⚠ 同名 CNAME→A 不能共存：一次 apply 可能先建后删、报冲突
   （与 pdns 的类型变更坑同理）。分两次 apply：先移除 ingress（CNAME 随之删除），再加 A 记录。
   中间断开约一分钟，此时本来就处于冻结窗口。
   第二次 apply 同时删除 `cloudflare_ruleset.custom_firewall`（git.ddupan.top 的爬虫挑战，ruleset 里只有
   这一条）。不能更早删：切换前 Gitea 还在 laptop 上，爬虫会再次打满它和 pg-prod。也不能留：
   切换后 lab 内也经 Cloudflare 访问，`/raw/`、`/archive/` 上的挑战会拦下 Backstage 等非浏览器客户端。
   新 Gitea 用 `REQUIRE_SIGNIN_VIEW = expensive` 接替（只拦匿名，带 token 的客户端不受影响）。
2. 按 `infrastructure/dns/records.yml` 的流程删除 `git.ddupan.top` 的 split-horizon 记录（blocky +
   coredns）。这一步不能等 Flux，手工应用，之后在新 Gitea 上补 commit。
3. 在 LAN、pod 和外网三处都验证解析结果和 `https://git.ddupan.top/api/healthz`。

### 4. 解冻与验收

- 三个 Flux source Ready，有新 commit 时能被拉取。
- runner 注册信息在数据库里，随迁移带过来；dynamic-runner 恢复后跑通一个 workflow。
- Renovate 跑一次；image-automation 推送一次。
- 用 `sso` 和 Entra ID 各网页登录一次，用 token 推送一次，发一封测试邮件。
- `platform/observability/metrics/probes/probes.yaml` 里 `git.ddupan.top` 的外部探测保留，
  删掉 split-horizon 那个 Probe。

### 5. 收尾（观察 2 周后）

- 删除 `apps/gitea`（HelmRelease、HTTPRoute、ExternalSecret、`database.yaml`）、
  `platform/cert-manager/certificate-git-ddupan.yaml`，以及 cloudflared 里旧的 ingress。
- PVC `gitea-shared-storage` 等 2 周后再删；pg-prod 的 `gitea` 租户库通过
  `clusters/ayatori-*` 退租。
- 更新 CLAUDE.md 的重建顺序：repo 已经不在 lab 内。

## 回滚

- **新 Gitea 产生写入之前**：把 DNS（A 记录 → tunnel CNAME，同样分两次 apply）和 split-horizon 改回去，scale 旧 Deployment 到 1，
  解除 HelmRelease 的 suspend。pg-prod 和 PVC 都没有动过。
- **已经产生写入之后**：反向迁移（`gitea dump --database postgres` 后导回 pg-prod），或者接受
  丢失窗口内的写入。单用户实例，窗口很短，所以第 4 步验收要尽快做完。

## 升级（迁移后）

Renovate 改 Compose 里的 tag → 合并 → 手工 `ansible-playbook gitea.yml`（独立 playbook，照 `watcher.yml` 的样子）。
不交给 CI：runner 跑在 lab 里，又要连接这个正在重启的 Gitea。备份 timer 前一晚已经跑过；跨 minor
升级前再手工 `gitea dump` 一次。
