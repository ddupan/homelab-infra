# Ayatori LoadBalancer 主机

Ayatori LoadBalancer（ADR-0012）的数据面主机：HAProxy + Data Plane API + gobgpd。主机配置由
Cinc（`homelab_loadbalancer` cookbook）负责，`lb_*` 配置段与 VIP 宣告由 Ayatori 负责。网络规则见
[`../network/README.md`](../network/README.md)。

| 主机 | 环境 | PVE | VMID | 地址 |
|---|---|---|---|---|
| lb-prod-1 | prod | pve3 | 160 | 10.60.0.30 |
| lb-prod-2 | prod | pve1 | 161 | 10.60.0.31 |
| lb-dev-1 | dev | pve1 | 162 | 10.60.0.32 |
| lb-dev-2 | dev | pve2 | 163 | 10.60.0.33 |

- 每个环境两台、分在不同 PVE 节点；pve3 按约定放基础设施，Prod 有一台在那里。
- 无特权 LXC，Debian 13，1 核 / 512 MiB / 4 GiB `local-lvm`。主机无状态：Cinc 重建节点配置，
  Ayatori 重新收敛 `lb_*`，所以不用 DRBD，也不进 PVE HA（冗余靠两台主机和 BGP）。
- 放在 labnet；环境由 BGP AS 区分（Prod 65100、Dev 65101），与地址无关。邻居是 VyOS
  `10.60.0.1`，它对内以 AS 65002 出现；VyOS 侧每台主机一条静态邻居。
- 部署时才确定的值（AS、邻居、VIP 段、Basic 哈希）在
  `../chef/policies/loadbalancer-{prod,dev}.rb`，不在 cookbook 里。

## 部署顺序

1. **建 LXC 并注册 DNS**（需要 `BAO_TOKEN` 读 PowerDNS key，laptop 上 SPIFFE
   `local-development` 登录即可）：
   ```bash
   cd infrastructure/loadbalancer/ansible
   ansible-playbook lxc.yml --check
   ansible-playbook lxc.yml
   ```
2. **Cinc converge**（首次会做 SPIRE enrollment，同样需要 `BAO_TOKEN`）：
   ```bash
   cd infrastructure/chef/ansible
   ansible-playbook converge.yml --check -l 'lb-*,localhost'
   ansible-playbook converge.yml -l 'lb-*,localhost'
   ```
3. **VyOS 接入**：`LB-PROD`/`LB-DEV` peer-group 与每台主机的静态邻居（另行变更）。
4. **OSPF→BGP 切换**（网络规划迁移清单第 1 条）：在此之前 IX 没有 10.62 的路由，LAN 访问不到 VIP。
5. **Ayatori 侧**：凭据 ExternalSecret 与 `--loadbalancer-host=<名字>.lab.ddupan.top,...` 参数。
   主机必须以 lab 名访问：服务端证书经 ACME 签发，没有 IP SAN。
