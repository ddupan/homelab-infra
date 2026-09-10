# DNS 声明与权威边界

`records.yml` 是 homelab DNS 的唯一声明清单，但不是 DNS 服务本身。不同视图仍由最适合
它们的后端提供：

| 视图 | 权威或递归服务 | 配置方式 |
|---|---|---|
| 公网 `ddupan.top` | Cloudflare | Terraform；尚待完整导入已有记录 |
| AD `ad.ddupan.top` | Samba internal DNS | `samba_dns_record` Ansible module |
| LAN split horizon | Blocky | 尚待从 inventory 渲染或校验 |
| Kubernetes Pod split horizon | CoreDNS | 尚待从 inventory 渲染或校验 |

## 安全边界

- Samba module 只管理 `homelab_dns.samba.records` 明确列出的 RRset，不遍历或清理 zone。
- `_ldap`、`_kerberos`、域控制器 locator 等由 Samba 自动维护的记录不进入 inventory。
- 一个受管 RRset 默认使用 `exact: true`：同名同类型的额外值会被删除，但其他名称和类型
  不受影响。
- DHCP 切换不属于本阶段。Blocky 仍未成为 LAN 客户端的正式 resolver。

## 分阶段接管

1. 用 Samba module 接管现有静态 A RRset，首次 check mode 应为零变更。
2. 将 Cloudflare 已有 tunnel DNS 记录导入 Terraform state。
3. 让 Blocky 与 CoreDNS 从 `split_horizon.records` 生成配置或执行 CI 一致性检查。
4. 验证公网、LAN、Pod、AD 四个视图后，再单独修改 DHCP。

当前 inventory 已明确暴露一个既有差异：`obj.ddupan.top` 在 Blocky 中存在，但 CoreDNS
尚无对应覆盖。本阶段不会偷偷修复它；后续在两个 resolver 同时接管时统一修复。
