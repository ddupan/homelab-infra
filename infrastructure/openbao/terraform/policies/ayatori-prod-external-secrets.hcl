# Ayatori Prod 控制面的 ESO：只读 Prod 实例的专用管理凭据与 PowerDNS API key。LoadBalancer 管理 API
# 的客户端证书与 Basic 凭据随 Ayatori ADR-0022 撤掉：manager 不再连接 LB 主机。
path "kv/data/infra/postgresql/ayatori/prod" {
  capabilities = ["read"]
}

# PowerDNS API key：LB API 写入 lb.lab.ddupan.top。pdns 只有一把不分 zone 的 key，
# 因此等同于对其全部 zone 的写权限，维护者已接受（2026-10-09）。原地读取而不复制，
# 轮换时所有使用方同时生效。
path "kv/data/k8s/powerdns" {
  capabilities = ["read"]
}
