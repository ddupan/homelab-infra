# Ayatori Prod 控制面的 ESO：只读 Prod 实例的专用管理凭据、PowerDNS API key，
# 以及 LoadBalancer 管理 API 的客户端凭据。
path "kv/data/infra/postgresql/ayatori/prod" {
  capabilities = ["read"]
}

# PowerDNS API key：LB API 写入 lb.lab.ddupan.top。pdns 只有一把不分 zone 的 key，
# 因此等同于对其全部 zone 的写权限，维护者已接受（2026-10-09）。原地读取而不复制，
# 轮换时所有使用方同时生效。
path "kv/data/k8s/powerdns" {
  capabilities = ["read"]
}

# LoadBalancer 客户端证书：只能从本环境的独立根签发（见 pki-loadbalancer.tf），
# LB 主机只信任该根，因此 Dev 控制面拿不到 Prod LB 的管理权。
path "pki-loadbalancer-prod/issue/ayatori" {
  capabilities = ["create", "update"]
}

# dataplaneapi Basic 密码明文；LB 主机只持有其 SHA-512 crypt 哈希。
path "kv/data/infra/loadbalancer/prod" {
  capabilities = ["read"]
}
