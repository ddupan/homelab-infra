# gitea-backup-drive

Gitea（oci-arm）每天把 `gitea dump` 传到 OCI 桶 `gitea-backup`，那里只留 **2 天**，
目的是省下免费额度（10 GB）给其他备份。这个 CronJob 每 6 小时把桶里的 dump 用 rclone crypt
加密后拷到 Google Drive 的 `homelab-backup/gitea/`，在那里保留 **30 天**。

| 位置 | 保留 | 谁能删 |
|---|---|---|
| OCI `gitea-backup` | 2 天 | 只有 lifecycle 规则；Gitea 主机只能新建 |
| Google Drive | 30 天 | 这个 Job（`drive.file` scope，只能碰 rclone 自己建的文件） |

清理有防护：Drive 上没有 2 天内的 dump 时不删任何东西，并以失败退出。这样 Gitea
备份停了也不会在 30 天后把 Drive 清空，同时 `GiteaBackupDriveStale` 会报警。

## 首次设置

Bao 路径：`kv/k8s/gitea-backup-drive`，四个 key：`oci_access_key`、`oci_secret_key`、
`drive_token`、`crypt_password`。

1. **crypt 密码**（合并前）：生成随机密码，用 `rclone obscure -` 处理（从 stdin 读，不进 argv），
   把同一个值写进两处：
   - `kv/k8s/gitea-backup-drive` 的 `crypt_password`
   - `kv/infra/terraform/oci` 的 `gitea_backup_drive_crypt_password`（用 `bao kv patch`，
     不要整份覆盖）。CI 的 plan 读不到它会直接失败，然后 Terraform 把它存进 OCI Vault
     `recovery` 的 `gitea-backup-drive-recovery`，lab 全挂时从 OCI 控制台取。
2. **Drive 授权**（合并前，需要浏览器）：在有浏览器的机器上，用 Google One 那个账号登录：
   ```bash
   rclone config create gdrive drive scope=drive.file   # 会打开浏览器授权
   rclone config show gdrive   # 取 token = 后面的整段 JSON
   ```
   把 JSON 写进 `drive_token`，然后删掉这台机器上的 `gdrive` 配置（`rclone config delete gdrive`）。
   用的是 rclone 自带的 OAuth client，refresh token 不会过期；每天一个文件，共享配额足够。
3. **合并**：CI apply `infrastructure/oci/terraform`，生成只读用户 `gitea-backup-drive` 的
   Customer Secret Key。Flux 部署这个 Job；在下一步之前 ExternalSecret 不会 Ready。
4. **OCI 凭据**：取 output `gitea_backup_drive_access_key` 和 `gitea_backup_drive_secret_key`
   （后者是 sensitive，用 `tf.py ... output -raw`，别打到终端以外的地方），写进
   `oci_access_key`、`oci_secret_key`。
5. 手动跑一次，在 Drive 网页上确认 `homelab-backup/gitea/` 下出现了 `.tar.gz.bin`：
   `kubectl --context default -n gitea-backup-drive create job --from=cronjob/gitea-backup-drive manual-1`

## 恢复

Drive 网页直接下载 `.bin` 文件，或者用 rclone 连同解密一起完成。crypt 密码在 Bao，
或者在 OCI Vault 的 `gitea-backup-drive-recovery` 中（obscure 后的值）：

```bash
export RCLONE_CONFIG_GD_TYPE=crypt RCLONE_CONFIG_GD_REMOTE=/path/to/downloaded/dir
export RCLONE_CONFIG_GD_FILENAME_ENCRYPTION=off RCLONE_CONFIG_GD_DIRECTORY_NAME_ENCRYPTION=false
read -rs RCLONE_CONFIG_GD_PASSWORD; export RCLONE_CONFIG_GD_PASSWORD
rclone copy gd: ./gitea-restore   # 得到 gitea-<时间>.tar.gz
```

解包后按 `docs/gitea-oci-migration-plan.md` 第 2 步导入。

## 告警

`GiteaBackupDriveStale`：24 小时没有一次成功。OCI 只留 2 天，所以还有大约一天的时间修复，
超过的话 Drive 上会缺那几天的 dump。
- 日志里有"跳过清理"：Gitea 没出新 dump，去查 oci-arm 上的 `gitea-backup.timer`。
- `invalid_grant`：Drive 授权被撤销，重做首次设置的第 2 步。
