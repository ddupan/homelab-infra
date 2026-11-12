# laptop：k3s 备份

`laptop-k3s-backup.yml` 每天 04:15 左右备份 k3s 的 SQLite 数据存储（`server/db/state.db`）和
`server/token`。两者缺一不可：token 是数据存储里 bootstrap 数据（集群 CA、SA 签名密钥等）的加密密钥
（[k3s 文档](https://docs.k3s.io/datastore/backup-restore)）。应用本身能靠 Flux + ESO 从 git 和 Bao
重建；这份备份保住的是集群身份，丢了它所有 kubeconfig、ESO / SPIRE 对 k8s 的信任都要重建。

| 副本 | 位置 | 保留 |
|---|---|---|
| 本地 | laptop `/var/backups/k3s/*.tar.zst`（明文，仅 root） | 最新 7 份 |
| 异地 | OCI 桶 `k3s-backup`，GPG 加密给 YubiKey | 7 天（lifecycle） |

laptop 对这个桶只能新建对象（`infrastructure/oci/terraform/k3s-backup.tf`）。失败时 `k3s-backup.service`
进入 failed，`HostSystemdUnitFailed` 告警；timer 停了由 `K3sBackupTimerStale` 告警。

## 首次设置

1. 合并后 CI apply `infrastructure/oci/terraform`，把 output `k3s_backup_access_key`、`k3s_backup_secret_key`
   写进 Bao `kv/infra/k3s-backup` 的 `access_key`、`secret_key`。
2. 运行 play（`--check --diff` → 正式 → 再跑一次应为 `changed=0`），再手动触发一次：
   ```bash
   VAULT_TOKEN=... ansible-playbook -i localhost, infrastructure/host-backup/laptop-k3s-backup.yml
   sudo systemctl start k3s-backup.service
   ```

## 恢复

取最新的本地 `.tar.zst`；本地没了就从 OCI 控制台下载 `.gpg`，`gpg -d`（触摸 YubiKey）。然后：

```bash
sudo systemctl stop k3s
sudo mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.old
sudo install -d -m 700 /var/lib/rancher/k3s/server/db
zstd -dc k3s-laptop-<时间>.tar.zst | sudo tar -C /var/lib/rancher/k3s/server/db -xf - state.db
zstd -dc k3s-laptop-<时间>.tar.zst | sudo tar -xOf - token | sudo tee /var/lib/rancher/k3s/server/token >/dev/null
sudo systemctl start k3s
```

全新安装的 k3s 也一样：先停掉 k3s，再放回 `db/` 和 token。恢复后 Flux 会把集群拉回 main 的状态；
备份之后才建的资源要等 Flux 重新应用。
