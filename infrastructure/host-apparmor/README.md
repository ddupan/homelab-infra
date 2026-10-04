# laptop AppArmor profile

安装 exporter 专用 profile 并以 enforce 加载。profile 本体在
`platform/observability/metrics/exporters/apparmor/`，说明见同目录的 `README.md`。

在 laptop 上执行（需要免密 sudo）：

```bash
ansible-playbook -i localhost, infrastructure/host-apparmor/laptop-apparmor.yml --check --diff
ansible-playbook -i localhost, infrastructure/host-apparmor/laptop-apparmor.yml
sudo grep homelab /sys/kernel/security/apparmor/profiles     # 每个都应为 (enforce)
```

第二次运行应 `changed=0`。修改 profile 后重跑即可原位重载，无需重启 Pod。

⚠ 顺序：**先跑本 play，再合并引用 profile 的 manifest**。Pod 引用未加载的 profile
会起不来；node-exporter 一挂就丢掉全部主机指标。删除 profile 时反过来：先去掉引用并让
Pod 滚动完成，再卸载。
