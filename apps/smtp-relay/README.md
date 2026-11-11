# SMTP relay (Postfix → OCI Email Delivery)

lab 内部统一的出站 SMTP 入口。客户端不认证、明文提交到 :25，relay 用 SASL 用户名密码经
STARTTLS（强制）转发到 OCI Email Delivery。只能以 **`noreply@ddupan.top`** 发信（OCI 的已批准发件人）。

```
k3s 内的应用 ─┐
              ├─ :25 明文 ─▶ smtp-relay（boky/postfix）─ 587 STARTTLS + SASL ─▶ smtp.email.ap-osaka-1.oci.oraclecloud.com
PVE 节点 ─────┘   （LAN：192.168.10.127:25，service-lan.yaml）
```

- 集群内：`smtp-relay.smtp-relay.svc.cluster.local:25`。
- PVE 节点：`infrastructure/proxmox/ansible/roles/pve_mail_relay`（relayhost 加发件人改写）。
- 2026-11 前转发到 M365（sasl-xoauth2 加 Entra 应用），ddupan.top 的 M365 开发者沙盒约 2027-01-23
  被清退，随之改为 OCI。

## 凭据

用户、SMTP 凭据、发件人和 DKIM 都在 `infrastructure/oci/terraform`（`smtp-relay-mail.tf`、`gitea-mail.tf`），
随 CI apply。凭据只在创建时返回，apply 后由人写进 Bao，ESO 同步给 relay：

```bash
cd infrastructure/oci/terraform   # 按该 root 的 README 准备 state 与 OCI 凭据
U=$(terraform output -raw smtp_relay_smtp_username)
P=$(terraform output -raw smtp_relay_smtp_password)
bao kv put kv/k8s/smtp-relay RELAYHOST_USERNAME="$U" RELAYHOST_PASSWORD="$P"
unset U P
kubectl --context default -n smtp-relay annotate externalsecret smtp-relay-secret force-sync=$(date +%s) --overwrite
kubectl --context default -n smtp-relay rollout restart deploy/smtp-relay
```

Bao 不可用时：`secret.example.yaml` 复制成 `secret.yaml`（gitignored）填值后 `kubectl apply`。

## 访问控制

设了 `ALLOWED_SENDER_DOMAINS` 后，镜像对**任何能连上端口的客户端**放行（`smtpd_relay_restrictions=permit`），
只检查发件人域名。所以真正的访问控制在网络层：

- `service.yaml`：ClusterIP，仅集群内。
- `service-lan.yaml`：`loadBalancerSourceRanges` 只放三台 PVE。klipper 会把 LAN 客户端 SNAT 成
  `10.42.0.1`，Postfix 分不清来源，**这里的源地址列表是唯一的门**，不要删。验证时要从被移出列表的
  那台 PVE 上实测被拒，在 k3s 本机上测走的是另一条 iptables 路径，会得出错误结论。

## 测试

```bash
kubectl --context default -n smtp-relay exec deploy/smtp-relay -- sh -c \
  'printf "Subject: relay test\n\nhello\n" | sendmail -f noreply@ddupan.top you@example.com'
kubectl --context default -n smtp-relay logs deploy/smtp-relay --tail=40   # 找 status=sent
```

## 送达

- DKIM：`oci-kix-202611._domainkey`（OCI 签名，d=ddupan.top），记录在 `infrastructure/cloudflared/terraform/mail.tf`。
- SPF 不含 OCI：信封发件人是 Oracle 的域名，SPF 本来就对不齐，DMARC 靠 DKIM 对齐通过。
- 免费额度每月 3000 封，与 Gitea 共用。
