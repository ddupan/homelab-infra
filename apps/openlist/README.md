# OpenList：OneDrive 网关

把租户里专用账号的 OneDrive 以网页和 WebDAV 提供给 lab。入口 `https://openlist.lab.ddupan.top`。
备份由 restic 在客户端加密后经 WebDAV 写入；**恢复不依赖这个服务**，可以用 rclone 直连 OneDrive。

存储挂载、用户和 SSO 都在 OpenList 的数据库里，只能在管理界面配置，所以下面的初始化是手工的。

## 初始化

1. Entra：按 `infrastructure/ddupan-entra/terraform/README.md` 建账号和应用，拿到 `client_id`、`client_secret`。
2. 写入管理员密码（只执行一次，不要进终端历史）：
   `openssl rand -base64 24 | bao kv put -mount=kv k8s/openlist admin_password=-`
3. 取 refresh token，在能开浏览器的机器上用专用账号登录。不要用 `api.oplist.org`，那样 token 会经过第三方：
   `rclone authorize onedrive <client_id> <client_secret>`
4. 管理界面 → 存储 → 添加 `OneDrive`：不勾“使用在线 API”，区域 `global`，填 `client_id`、`client_secret`、
   回调地址 `http://localhost:53682/` 和第 3 步 JSON 里的 `refresh_token`。
5. 设置 → 单点登录：平台 `OIDC`，端点 `https://sso.ddupan.top`，用户名字段 `preferred_username`，打开自动注册，
   默认权限保持 `0`。client 见 Bao `kv/k8s/openlist-sso`。
6. 每个备份客户端建一个用户：基本路径设成自己的目录，只开 WebDAV 读取、WebDAV 管理和所需的文件权限。
