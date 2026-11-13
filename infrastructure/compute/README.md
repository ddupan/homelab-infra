# Ayatori 计算节点

Ayatori 自建计算后端（Ayatori ADR-0015）的节点：libvirt/LXC 实例跑在里面，由节点上的 Compute Agent
按 Ayatori API 收敛。Dev 节点是 PVE 上的 VM（嵌套 KVM）；节点配置由 Cinc 负责（policy
`../chef/policies/compute-dev.rb`）。

| 主机 | 用途 | PVE | VMID | 地址 | 规格 |
|---|---|---|---|---|---|
| compute-dev-1 | 实例 | pve1 | 170 | 10.60.0.50 | 4 核 / 6 GiB / 40 GiB |
| compute-dev-2 | 实例 | pve2 | 171 | 10.60.0.51 | 2 核 / 2 GiB / 20 GiB |
| compute-dev-3 | DRBD 仲裁（ADR-0020），不跑实例 | pve3 | 172 | 10.60.0.52 | 1 核 / 1 GiB / 10 GiB |

- 每台在不同 PVE 节点。pve2、pve3 内存只有 8 GiB，只有 pve1 上的一台给得多。
- Debian 13 genericcloud，CPU type `host`（嵌套 KVM），开 balloon（下限为一半），根盘在 `pve-rg-hdd`
  （local-lvm 放不下）。节点无状态：配置由 Cinc 重建，实例归 Ayatori，所以不进 PVE HA。
- 放在 labnet，网关 VyOS `10.60.0.1`。

## 部署顺序

1. **建 VM 并注册 DNS**（需要 `BAO_TOKEN` 读 PowerDNS key，laptop 上 SPIFFE `local-development` 登录即可）：
   ```bash
   cd infrastructure/compute/ansible
   ansible-playbook vm.yml --check
   ansible-playbook vm.yml
   ```
   cloud-init 用户 `panxiao81` 只放操作者的公钥。SSH host key 经 PVE 上的 qemu-guest-agent 读取
   （vendor-data 安装它），写进本机 known_hosts；同时追加到 `../chef/known_hosts` 供 CI 使用。
2. **首次 Cinc converge 由操作者在本机运行**：装上 Bao SSH CA 信任之前，CI 的证书登录不了。
   ```bash
   cd infrastructure/chef
   ./converge.py -l compute-dev
   ```
3. **SPIRE enrollment**：`BAO_TOKEN=... ansible-playbook enroll.yml -l 'compute-dev-*'`（见 `../chef/README.md`）。
   node alias 与 Agent 的身份在 `platform/spire/`。
4. Ayatori 发布含计算后端的 release 后，policy 加上 `homelab_compute`，再按 `../chef/ansible/join.yml`
   让 Agent 加入控制面。
