# laptop：自动更新与服务重启

`unattended-upgrades` 照常安装安全更新；`laptop-needrestart.yml` 只改 needrestart 的行为：库升级后，
**有状态/承载性的服务只报告、不自动重启**（PG / etcd / NFS / k3s / containerd / docker / libvirtd /
incus / tailscaled / cloudflared），其余仍按默认自动重启。

起因：2026-10-09 06:36 `libxml2` 的安全更新让 needrestart 自动重启了 Patroni leader（pg-prod），主库
被动切到 pve1，pg-dev 和 nfs-server 也被重启。

被跳过的服务会继续运行旧库，直到人为重启。查看哪些服务在等重启：

```bash
sudo needrestart -r l          # 只列出，不重启
```

重启 pg-prod 前先用 Patroni switchover 把 leader 挪走，再重启该节点的服务。
