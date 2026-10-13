# 已退役：k3s 内 CloudNativePG（`shared-db/shared-postgresql`）

2026-10-13 退役。单实例 CNPG（PG 18.3，`localpv-zfs-ceph` 10 GiB），所有应用已迁到 k3s 外的
pg-prod（Patroni + PgBouncer，`infrastructure/shared-postgresql/`），各自经 Ayatori 租户申请
（`clusters/ayatori-prod/`）。本目录是当时的清单与迁移 runbook，**只作历史，不再应用**。

| 原库 | 去向 | 连接 |
|---|---|---|
| backstage | pg-prod `backstage`（#367） | 直连 5432（events 用 LISTEN/NOTIFY） |
| e5renew | pg-prod `e5renew`（#368，同时改由 Flux 部署） | 池 6432；迁移 Job 直连 |
| `postgres` 库中 research-auto 的 18 张表 | pg-prod `research_auto`（#370） | 池 6432；yoyo 迁移直连 |
| gitea | pg-prod `gitea`（#371/#372） | 直连 5432（lib/pq 不能经池） |
| spire | pg-prod `spire`（#374） | 直连 5432（lib/pq） |
| hydra、`postgres` 库中 Keycloak 的表、shared_data（空） | 不迁移，只在下方存档中 | — |

## 最终存档

退役前 `pg_dumpall --clean --if-exists`（所有库与角色，含密码哈希）流式加密，明文从未落盘：

- 对象：SeaweedFS `s3://archive/cnpg-shared-postgresql-pg_dumpall-20261013T134855Z.sql.gpg`
- 加密：gpg，仅加密给 cv25519 子密钥 `5A6A04D1B216C64E`（主钥 `0166F47B5400ECC2`，YubiKey；同
  `.vault_pass.gpg`）。**子密钥 2027-04-07 到期**——轮换时要么用新子密钥重新加密本存档，要么保留旧私钥。
- 明文：135711628 字节，sha256 `f6231c92c5e20876d696a88666d6cfeb2c0285ae11030c948e0fe66b8303b901`，以 `PostgreSQL database cluster dump complete` 结尾
- 密文 sha256 `3db7e600c4ec3c6f1531c106a4bec038cc1fce817727bf50e5e6270747b0a1b2`

恢复（需 YubiKey）：`gpg -d cnpg-shared-postgresql-pg_dumpall-20261013T134855Z.sql.gpg | psql -X -v ON_ERROR_STOP=1 -d postgres`，目标为空实例；
只要某一个库时，从解密流里截取该库的 `\connect` 段即可。

## 教训（已写入相应 README）

- 判断表是否为空用 `count(*)`，不要用 `pg_stat_user_tables.n_live_tup`：崩溃重启会清零（CNPG 重启过 11 次），
  据此一度误判 research-auto 没有数据。
- PgBouncer transaction 模式下 lib/pq 不可用（未命名语句跨两次 Sync）；接入池前做并发验证。
- 挂起子 Kustomization 要用自定义 `--field-manager`，否则会被 `flux-system` 撤销。
