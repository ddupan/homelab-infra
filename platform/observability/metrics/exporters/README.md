# 主机与进程内存采集

2026-09-16 已增加 `process-exporter.yaml`，固定上游 0.8.7，以 DaemonSet 运行，
只读挂载宿主机 `/proc`，每 60 秒由 VMPodScrape 抓取，不开宿主机端口。
NetworkPolicy 仅放行同 namespace 的 vmagent。进程按名称分组，QEMU 按 guest 名，
VS Code 按路径归组；不把完整命令行或 PID 放进指标标签。

当前 live 使用 `gather-smaps=true`，导出 RSS、VmSwap、PSS、SwapPss 与进程数。
`apparmor/homelab-process-exporter` 已安装到 `/etc/apparmor.d/homelab-process-exporter`
并以 enforce 加载。用户明确批准了跨进程读取：SYS_PTRACE、DAC_READ_SEARCH 与
`ptrace (read) peer=**`；文件权限限于指标需要的 proc 文件，不允许 ptrace trace，
不开放 `/proc/<pid>/mem`、`environ`，不关闭 AppArmor，也未修改虚拟机或容器默认 profile。

当前只部署到 laptop。其他节点必须先安装同名 profile，再扩展 nodeSelector：

```bash
sudo install -m 0644 apparmor/homelab-process-exporter /etc/apparmor.d/homelab-process-exporter
sudo apparmor_parser -r /etc/apparmor.d/homelab-process-exporter
```

修改 profile 可原位重载，无需重启业务。禁用时先删除 exporter DaemonSet，再卸载
专用 profile；不要让引用 profile 的 Pod 在 profile 缺失时启动。

验证已读到三台虚拟机、NetBox、Codex 的非零 PSS/SwapPss。`namedprocess_scrape_errors`
和 `namedprocess_scrape_procread_errors` 为零。上游会先读取再匹配进程，内核线程没有
可读的 smaps_rollup 会计入 partial errors；现场有约 430 个这种线程。
partial errors 不保证为零，应结合业务组 PSS 和 AppArmor 审计判断。
RSS、PSS、cAdvisor working set、ARC 是不同口径，不能直接相加。

已有采集无需重复部署：

- node-exporter：主机内存、Swap、PSI、ZFS ARC。
- ARC 实际指标名为 `node_zfs_arc_size`、`node_zfs_arc_c`、`node_zfs_arc_c_max`。
- kubelet/cAdvisor：Pod/container working set、Swap 等。

Grafana 新增 `Homelab 内存与 Swap`（UID `homelab-memory`），由 sidecar ConfigMap 加载。
仅使用 `job="node-exporter"` 查询主机指标。（曾有 `docker-hosts` job 重复抓取同一 9100
端口，2026-11-03 随未部署的 docker-hosts 栈一并删除。）

所有新增 manifest 已纳入对应 Kustomization，并已单独应用到 live；尚未提交到远端，
Flux source 尚未包含这些新增资源。修改 exporter ConfigMap 后需滚动重启 DaemonSet，
程序不会自动重载进程匹配配置。

## node-exporter 的 AppArmor profile（systemd collector）

#215 给 node-exporter 开了 `--collector.systemd`，但在笔记本上**一直失败**：
`couldn't get dbus connection: An AppArmor policy prevents this sender from sending this message`。
Pod 跑在 containerd 默认 profile `cri-containerd.apparmor.d` 下，它没有任何 dbus 规则，而宿主
dbus-daemon 会做 AppArmor 仲裁，所以连 `Hello` 都被拒。现象只有
`node_scrape_collector_success{collector="systemd"} == 0`，其余 collector 不受影响，
`HostSystemdUnitFailed` 对笔记本静默失效（bao1 用的是 Debian 包的 node-exporter，不受影响）。

`apparmor/homelab-node-exporter` = 默认模板照抄 + 只读查询 systemd 的 dbus 规则（ListUnits*、
GetUnit、Properties.Get/GetAll），不放开任何改变 unit 状态的 member。不用 `Unconfined`：
node-exporter 挂了宿主 `/`、开着 hostPID，去掉 AppArmor 的代价不对等。

**顺序很重要**——Pod 引用一个未加载的 profile 会起不来，DaemonSet 一坏就丢掉全部主机指标。
profile 由 `infrastructure/host-apparmor/laptop-apparmor.yml` 安装并加载（同时接管
process-exporter 的 profile），2026-10-04 已在 laptop 执行，二次运行 `changed=0`。
扩展到其他节点前先在该节点跑这个 play。

2026-10-04 用一次性 Pod（同镜像、同挂载、只开 systemd collector）验证：
`node_scrape_collector_success{collector="systemd"} 1`，约 1965 条 unit_state 序列 + 21 个
timer，内核与 dbus 日志均无 `DENIED`。之后再让 DaemonSet 引用该 profile。

验证（端口在宿主网络上）：

```bash
curl -s localhost:9100/metrics | grep 'node_scrape_collector_success{collector="systemd"}'   # 期望 1
sudo journalctl -k --since -10min | grep 'apparmor="DENIED".*homelab-node-exporter'           # 期望为空
```

有 DENIED 就按审计日志里的 path/member 补规则，重跑 play 原位重载即可，无需重启 Pod。

⚠ 一旦 systemd 指标进来，笔记本上现存的 failed unit 会各报一条 `HostSystemdUnitFailed`
（2026-10-04 有 6 个：nvidia-cdi-refresh ×2、nvidia-fabricmanager、rpc-svcgssd、
systemd-ask-password-console.path、systemd-networkd-wait-online，详见 #215）。这些告警是真实状态，清理 unit 即可恢复。
