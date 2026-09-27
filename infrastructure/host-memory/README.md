# laptop 内存预算

laptop 同时承载 Kubernetes、数据库和 libvirt VM。ARC 使用明确的 **4 GiB** 上限，
为服务留下突发余量；不修改自动 ARC 下限、swap、业务内存或 VM I/O 策略。

在 laptop 上执行：

```bash
ansible-playbook -i localhost, infrastructure/host-memory/laptop-arc.yml --check
ansible-playbook -i localhost, infrastructure/host-memory/laptop-arc.yml
```

play 在线写入 `/sys/module/zfs/parameters/zfs_arc_max`，并持久化到
`/etc/modprobe.d/homelab-zfs-arc.conf`。配置变化时以低 CPU/I/O 优先级更新所有已安装
内核的 initramfs。不重启、不卸载 ZFS。ARC 当前使用量不保证立即降到上限以下；
`zfs_arc_max` 也不是 ZFS 全部内存的硬上限。

验证 `/proc/spl/kstat/zfs/arcstats` 的 `c_max=4294967296`，并在 Grafana 比较
`node_zfs_arc_size`、`node_zfs_arc_c_max`、内存/I/O PSI、换页及数据库请求延迟。
命中率下降或磁盘读压力上升时按实际负载重新评估预算，不通过重启或清缓存进行验收。

回滚时先从运行中的 `arcstats` 核实原自动上限，再在线写回该非零值。
删除本 play 的 modprobe 文件并更新 initramfs，可恢复以后启动时的自动策略。
不要依赖运行时写入 `0` 恢复自动计算；该行为受 OpenZFS 参数实现限制。

2026-09-26 故障关联：winadmin 自动更新期间虚拟磁盘写入与 ARC 增长、内存回收和
Gitea 超时重合；限制 ARC 是内存预算措施，不代表已证明或解决全部存储延迟原因。
排查证据与后续验收见
[宿主机 ARC 预算](https://git.ddupan.top/panxiao81/homelab-wiki/src/branch/main/guides/laptop-arc-budget.md)。
