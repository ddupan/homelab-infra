# laptop Incus

Ansible 管理 Ubuntu 24.04 amd64 上的 Zabbly stable APT 源、公钥、固定包版本和
Incus 本地服务。当前版本为 `7.5.1`，完整 Debian 版本见
`ansible/group_vars/incus_hosts.yml`。使用系统包，不使用 snap。

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-incus ansible-playbook -i infrastructure/incus/ansible/inventory/hosts.yml infrastructure/incus/ansible/site.yml --syntax-check
ANSIBLE_LOCAL_TEMP=/tmp/ansible-incus ansible-playbook -i infrastructure/incus/ansible/inventory/hosts.yml infrastructure/incus/ansible/site.yml --check --diff
ANSIBLE_LOCAL_TEMP=/tmp/ansible-incus ansible-playbook -i infrastructure/incus/ansible/inventory/hosts.yml infrastructure/incus/ansible/site.yml
```

执行者需有免密 sudo。首次机器没有包索引时，check 模式不能验证待安装包的可用性；
实际执行会刷新该源并校验包签名。重跑应 `changed=0`。

## 管理边界

- `site.yml` 管安装；`access.yml` 管 Web UI/OIDC 入口。不执行 `incus admin init`，不创建存储池、profile、实例或受管网络。
- 保留 libvirt VM、k3s、现有 bridge、路由和防火墙配置；不引入 OVN/SDN/LB。
- HTTPS listener 为 `192.168.10.127:8443`，域名入口经现有 Envoy；不新增 `incus-admin` 成员。本地 `sudo incus` 保留为恢复入口。
- etcd 和共享 PostgreSQL 由各自目录管理；此目录不迁移它们。
- 不自动删除旧实例或存储；历史 `data/incus` 已由维护者另行授权删除，非本 playbook 行为。

## 版本与公钥维护

公钥来自 Zabbly，主指纹为 `4EFC590696CB15B87C73A3AD82CC8797C838DCFD`，
与[上游安装说明](https://github.com/zabbly/incus)核对后随配置保存。
更新密钥时先核对上游指纹。版本由 APT preferences 固定；升级需修改变量，
审阅 `--check --diff` 后执行，不自动降级。
上游 stable 源未承诺永久保留旧构建，长期离线重建需另行保存包及依赖。

## 验证与故障入口

```bash
sudo incus version
sudo incus list local:
sudo incus storage list local:
sudo incus network list local:
systemctl status incus.service incus.socket
sudo journalctl -u incus.service -n 80 --no-pager
```

网络列表可能展示宿主已有的非受管接口，不代表 Incus 创建了网络。
安装验收不等于实例运行验收；存储、实例备份恢复方案留待资源初始化时确定。
共享知识入口：`homelab-wiki/services/incus.md`（随本次变更同步）。

## Web UI 与 Authelia

入口：`https://incus.ad.ddupan.top`，选择 **Login with SSO**，使用 `panxiao81`
并完成 MFA。Authelia 专属 policy 默认 deny，仅此账号可取得 Incus token。
该客户端登录者具有 Incus 完整管理权限，不根据当前 AD 组放权。

CLI 可使用 `incus remote add laptop https://incus.ad.ddupan.top --auth-type=oidc`，
按设备码流程在浏览器中完成同一登录；token 由客户端保存在本机，不写入 Git。

声明分工：

- `apps/authelia/clients/incus.yaml`：单用户 MFA 准入、public client、PKCE S256、
  签名 access token、唯一 audience、浏览器回调和 device/refresh grants。
- `ansible/group_vars/incus_hosts.yml`：Incus OIDC issuer/client/audience/scopes 和 listener。
- `ansible/templates/gateway.yaml.j2`：独立 namespace、Service/EndpointSlice、HTTPRoute、
  BackendTLSPolicy。入口复用现有通配符证书，后端以 Incus 的公共 server.crt 验证
  `laptop` SAN，不跳过 TLS 验证。公共证书由 playbook 读取，不复制私钥。
- `infrastructure/dns/records.yml`：唯一 DNS 声明；`ansible/dns.yml` 只协调 Incus 与两个 Ayatori 容器的记录。

入口资源由此 Ansible playbook 管理，尚未交由 Flux。共享 Gateway 的后端 TLS
兼容配置由 Flux 管理：EnvoyProxy `eg` 允许 TLS 1.2–1.3，以连接要求 TLS 1.3
的 Incus；见 [PR #164](https://git.ddupan.top/panxiao81/homelab-infra/pulls/164)。
此补丁不升级网关、不改变前端证书或其他路由。
Authelia 当前不是 Flux 受管 release。协调脚本先读取 live Helm values，
仅合并 Incus client/policy，固定 chart 0.11.6 渲染后部署；保留 Hydra/Backstage 等
现有配置和秘密，禁止以滞后的 `apps/authelia/values.yaml` 全量覆盖线上 release。
临时 values 存在 0700 目录、0600 文件中并自动清理，部署前检查 release revision，
避免覆盖准备期间的并发 Helm 变更；仍应避免同时升级该 release。

```bash
# 先 site.yml 安装 UI，再接入；均先 --check --diff 再移除这两个参数执行。
ANSIBLE_LOCAL_TEMP=/tmp/ansible-incus ansible-playbook -i infrastructure/incus/ansible/inventory/hosts.yml infrastructure/incus/ansible/access.yml --check --diff

# DNS 使用既有 Samba inventory/collection，仅修改 Incus 的 RRset。
cd infrastructure/samba-ad/ansible
ANSIBLE_CONFIG=ansible.cfg ANSIBLE_COLLECTIONS_PATH=collections ANSIBLE_LOCAL_TEMP=/tmp/ansible-incus-dns ansible-playbook -i inventory/hosts.yml ../../incus/ansible/dns.yml --check --diff
```

执行接入需要本机 Python3/PyYAML、Helm、kubectl 及现有集群管理凭据；DNS 另需
既有 Samba Ansible vault 与 SSH 权限。首次入口 namespace 不存在时 check 使用
客户端 dry-run；存在后使用 kubectl diff。后续实际重跑要求 `changed=0`。

### 故障与迁移

- Web 入口和 OIDC 依赖 k3s/Envoy/Authelia；它们不可用时使用宿主 `sudo incus`，
  Incus daemon 与实例生命周期不依赖网页登录。
- `8443` 直连仍由 Incus 原生认证保护，但只注册域名 443 的 OIDC callback，
  浏览器登录应从正式域名进入。网关不透传客户端 TLS 证书；远程主要使用 OIDC。
- 更换宿主 Incus 证书后重跑 `access.yml`，同步网关公共信任证书。
- 未来切换 IdM：更新 issuer/client/audience/scopes 和新 provider 的准入策略，
  验证浏览器及 CLI 后再停用 Authelia client；本次不引入永久组模型。
- 移除用户准入不会立即撤销已签发的 JWT；紧急撤权需同时处理现有 token/会话。
- 回退入口时先撤 HTTPRoute，再关闭 `core.https_address`；保留本地管理和现有实例数据。

验证包括 DNS、TLS、route conditions、匿名 API 拒绝、PKCE/回调和设备码授权发起。
2026-09-25 维护者确认 `panxiao81` 完成 MFA 并成功返回 Incus 控制台。
安装、接入、DNS playbook 重跑均 `changed=0`；后续基础容器验收见下节。
未验证 Web 实例控制台或 Ayatori 应用数据路径。

## Ayatori 基础容器

`terraform/` 只管理 `ayatori-dev`、`ayatori-prod` 两个 Ubuntu 24.04 非特权 LXC，
以及专属 ZFS 存储池 `ayatori`（`data/incus-ayatori`）。每个容器上限 2 CPU、
2 GiB 内存、20 GiB rootfs，禁用容器 swap，自动启动。没有安装 Ayatori、k0s、
kube-apiserver、controller 或数据库；准备 Prod 空容器不代表生产服务已上线。

网络接入既有 `br0`，固定 MAC 分别为 `02:16:3e:aa:00:01`、`02:16:3e:aa:00:02`。
Terraform 通过 `cloud-init.network-config` 配置静态地址：Dev `192.168.10.11`、
Prod `192.168.10.12`（`ayatori-{dev,prod}.ad.ddupan.top`）。地址只在
`infrastructure/dns/records.yml` 声明一次，Terraform 与 AD DNS 均从此读取；须位于
NEC IX DHCP 池（`.128–.250`）之外。⚠ 镜像模板只在创建/复制时渲染 cloud-init seed，
对已有实例改地址不会生效（重启、`cloud-init clean` 都不行），只能重建实例。

SSH 全部由 cloud-init 完成：安装 openssh-server，创建 `panxiao81`（`ansible/files/panxiao81.pub`
公钥、免密 sudo），装包后再写 `/etc/ssh/sshd_config.d/60-homelab.conf` 关闭密码与 root 登录。
不使用 `ssh_pwauth`：它在装包前写出残缺的 `sshd_config`，包自带的 `UsePAM yes` 落不下来，
锁定密码的账号会被拒（2026-09-25 曾发生）。宿主也可使用 `incus exec local:ayatori-dev -- bash`。
provider 通过本地 Unix socket 操作，执行账号须有 socket 权限。

```bash
terraform -chdir=infrastructure/incus/terraform init
terraform -chdir=infrastructure/incus/terraform plan -out=containers.tfplan
terraform -chdir=infrastructure/incus/terraform apply -parallelism=1 containers.tfplan
terraform -chdir=infrastructure/incus/terraform output containers
terraform -chdir=infrastructure/incus/terraform plan -detailed-exitcode
```

provider 固定 1.2.0 并保留 lockfile。镜像跟随 `images:ubuntu/24.04/cloud` 最新构建，
只在创建时使用（`ignore_changes`）；不固定指纹，因为上游会下架旧构建，2026-10-01
重建时固定指纹已无法获取。
cloud-init 用户设置主要在首次启动执行，修改声明不能替代后续用户/密钥轮换流程。

当前 state 位于 `terraform/terraform.tfstate`（Git 忽略），是本地 backend；
现有 Bao 会话无法读取远端 tfstate 凭据，因此尚未启用远端 backend。
后续迁移须使用 `terraform init -migrate-state` 保留资源归属，不创建第二份独立 state。
实例和池启用 `prevent_destroy`；删除需显式审阅，不能通过移走整个资源块绕过保护。
当前为空系统，丢失后可重建；承载持久数据前须补离机备份与恢复验收。

首次从同一远端并行创建实例时，Incus 7.5.1 曾出现 simplestreams 缓存目录
`mkdir ... file exists` 竞争；按上面的串行 apply 执行。失败后先重新 plan，
保留已成功创建的实例，不清理或销毁其资源。
