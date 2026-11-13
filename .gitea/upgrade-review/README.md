# Renovate PR 升级评审

`flux-diff.yml` 的 `upgrade-review` job 在 renovate-bot 开的 PR 上运行 [pi](https://pi.dev)（coding agent），
判断升级在我们的配置下会不会坏，结论以评论贴到 PR。报告模式：只评论，不合并，不让 CI 变红。

| 文件 | 作用 |
|---|---|
| `review.py` | 外层：取网关 key、拼输入、以最小环境变量启动 pi、把事件流转成 OTel span、发评论 |
| `prompt.md` | 追加到 pi 系统提示词的评审要求 |
| `extension.ts` | pi 扩展：`fetch_url`（只读公网，SSRF 防线）与 `submit_review`（结构化结论） |
| `package.json` / `package-lock.json` | 锁定 pi 版本（`npm ci`，经 Artifact Keeper） |
| `review.py.lock` | `uv lock --script` 锁定的 Python 依赖 |

## 边界

- 工具只有 `read,grep,find,ls,fetch_url,submit_review`，没有 bash/edit/write。
- pi 的环境里只有网关 key：没有 `GITEA_TOKEN`、`BAO_TOKEN`；checkout 用 `persist-credentials: false`。
- `fetch_url` 拒绝非公网地址、`ddupan.top` 与集群内名字，每一跳重定向重新检查；runner Pod 在
  homelab 集群里，这是挡住 SSRF 的唯一一层。
- 网关 key 是 Bao `kv/k8s/ai-gateway-keys/upgrade-agent`，只有 role `ci-upgrade-review` 能读。
  在 key UI 吊销即停用评审。

## Bootstrap（一次）

评论以 restricted 的 Bot 账号 `upgrade-agent` 发出，只在 homelab-infra 上有 read 权限；token 只有
`write:issue,read:repository`。Gitea 在 OCI ARM 上（`infrastructure/oci/ansible/roles/gitea`）。

```bash
# 1. 账号。Bot 类型不能设密码（gitea: password can only be set for user accounts），只靠 token。
ssh ubuntu@oci-arm.ddupan.top sudo docker exec gitea-gitea-1 gitea admin user create \
  --username upgrade-agent --fullname "'Upgrade Agent'" --email upgrade-agent@users.noreply.ddupan.top \
  --user-type Bot --restricted

# 2. token 直接进 Bao，不回显。pipefail：生成失败时不能写入空 token。
set -o pipefail
ssh ubuntu@oci-arm.ddupan.top sudo docker exec gitea-gitea-1 gitea admin user generate-access-token \
  --username upgrade-agent --token-name upgrade-review --raw --scopes write:issue,read:repository \
  | tr -d '\n' | bao kv put -mount=kv k8s/upgrade-agent token=-

# 3. 只读 collaborator。
tea api -X PUT /repos/panxiao81/homelab-infra/collaborators/upgrade-agent -d '{"permission":"read"}'
```

以后放开自动合并时，合并或 approve 再另给权限，不扩大这把评论用的 token。

## 本地运行

```bash
cd .gitea/upgrade-review && npm ci --registry=https://artifacts.lab.ddupan.top/npm/npm-proxy/ && cd -
# 在要评审的 PR 的检出上运行；key 用本机 SPIFFE 身份从 Bao 读出（bao-ssh-access）
UPGRADE_REVIEW_API_KEY=... \
UPGRADE_REVIEW_OTLP_TOKEN=...  # kv/k8s/otel-collector public_token；不设则不导出 trace \
  uv run --script .gitea/upgrade-review/review.py --pr <N> --dry-run
```

## 观测

每次评审一条 trace（service `upgrade-review`），经 LAN 入口 `otlp.lab.ddupan.top`（collector 的 4319，
bearer token）导出——CI 的 pod job 在 sandbox 集群，解析不了 homelab 的 Service 名：根 span `upgrade_review` 下每轮一个 `turn N`（带 token
用量），每次工具调用一个 `tool <name>`；`traceparent` 经请求头带给 AI 网关，网关的 `chat <model>` span
在同一条 trace 里。评论末尾印有 trace id。

## 升级 pi

改 `package.json` 的版本后，`npm install --package-lock-only --registry=https://artifacts.lab.ddupan.top/npm/npm-proxy/`
重生成 lock；pi 以 headless 方式运行时 stdin 必须是 `/dev/null`，否则会一直等管道输入。
