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
仅使用 `job="node-exporter"` 查询主机指标，避免目前 `docker-hosts` 对同一 9100 端口
的重复抓取。另有 `192.168.10.127:8080` Docker cAdvisor target 失效，本次未修改该旧配置。

所有新增 manifest 已纳入对应 Kustomization，并已单独应用到 live；尚未提交到远端，
Flux source 尚未包含这些新增资源。修改 exporter ConfigMap 后需滚动重启 DaemonSet，
程序不会自动重载进程匹配配置。
