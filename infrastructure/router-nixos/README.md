# router-nixos（PoC）

验证 [router.md](../network/router.md)「备选：NixOS」的三条结论，**不碰 vm:100 的转发**：
PoC（vm:105，labnet 10.60.0.40）只和 vyos-rtr 建 eBGP，宣告一个 RFC 5737 文档地址，VyOS 侧全拒导入。

**状态（2026-11-04）**：验证通过，这套配置就是下一代路由器的起点；迁移未开始。PoC 的 VM、VyOS 邻居、
DNS 记录已撤掉，代码留着。重建时 VM 定义、VyOS 侧 `vyos_poc_peers`/`POC-IN` 模板见 #581 的改动。

## 结果（2026-11-04，nixos-26.05，FRR 10.6.1）

| 验证 | 做法 | 结果 |
|---|---|---|
| 改配置 BGP 不断 | `prefix-list OUT` permit→deny，deploy | **过**（需改 `ExecReload`，见下）：VyOS 收到的前缀消失，邻居 uptime 连续、dropped 计数不变；reload 1 秒 |
| 坏 `frr.conf` 被拦 | 写一条非法 FRR 语句 | **过**：`nix flake check` 失败（`Unknown command`，rc≠0），deploy 不发生 |
| 锁死自己能回退 | nftables 首条 `tcp dport 22 drop`（连已建连接一起断），同时改回 permit | **过**：17:25:02 激活，17:26:02（`confirmTimeout` 60s）目标机自行切回上一代，4 秒完成；nftables 与 FRR 都是 reload；之后新 SSH 可登录，BGP 全程未断 |

实测发现、写进代码或下面的坑：

- ⚠ **模块默认的 `frrinit.sh reload` 会让 BGP 断一次**：它重启 watchfrr，watchfrr 退出时发
  `STOPPING=1`，systemd 把 frr.service 当成在停，2 分钟后 SIGKILL 全部守护进程再拉起。两次部署
  各断一次（VyOS `dropped 2`）。脚本里的规避只认 cgroup v1。`router-poc.nix` 把 `ExecReload` 换成
  直接调 `frr-reload.py`，之后再未断过；顺带让 reload 失败能传到激活结果（原脚本无条件 `exit 0`）。
- ⚠ **magic rollback 回不到 nixos-anywhere 装的那一代**：那一代没有 `deploy-rs-activate`，回滚只把
  profile 指回去（"reactivate last generation: No such file or directory"），运行中的仍是新配置。
  首装后**先用 deploy-rs 部署一次无害变更**，之后才有可回退的上一代。
- 证书 5 分钟，而一次 deploy（容器里求值 + 复制 + 激活）要 5–10 分钟，确认时证书已过期，被当成
  "失联"回滚了两次。部署脚本签完证书立即开 SSH ControlMaster，后续连接复用它；证书只需在认证那一刻
  有效，不必加长 TTL。锁死测试里 `tcp dport 22 drop` 放在 `ct state established` 之前，否则复用的
  已建连接不受影响，测不出回滚。

## 构建与检查

本机不装 Nix，用容器（store 放在 docker volume，反复跑不重下）：

```sh
docker run --rm -v nix-poc-store:/nix -v "$PWD":/src -w /src \
  -e NIX_CONFIG='experimental-features = nix-command flakes' nixos/nix:2.28.3 \
  nix flake check -L path:/src
```

`path:` 而不是 git flake：worktree 的 `.git` 指向容器外，git 模式会找不到仓库。

## 部署

- 首装：pve_vm 起一台 cloud-init 的 VM，`nixos-anywhere --flake .#router-poc <user>@<addr>`
  kexec 进安装环境并按 `disk.nix` 分区。VM 定义归 Ansible，OS 归 Nix。
  ⚠ kexec 后安装环境会换一个 DHCP 地址（machine-id 不同），nixos-anywhere 会一直连旧地址；
  从串口（`qm terminal 105`）查新地址，`--phases disko,install,reboot --target-host root@<新地址>` 续装。
- 之后：deploy-rs（magic rollback，`confirmTimeout = 60`）。SSH 只认 Bao 签发的证书
  （`TrustedUserCAKeys`），用 bao-ssh-access 签 `root` principal，按上文开 ControlMaster：

```sh
O="-i id -o CertificateFile=id-cert.pub -o ControlPath=/tmp/cm -o ServerAliveInterval=5 -o ServerAliveCountMax=2"
ssh $O -fNM -o ControlPersist=20m root@10.60.0.40     # 签完证书立刻
nix run --inputs-from path:/src deploy-rs#deploy-rs -- --skip-checks path:/src#router-poc --ssh-opts "$O"
```
