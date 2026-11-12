# 远端 state，其他 root 的 S3 backend 都照此配置。
#
# 为什么要远端：本地 state 只存在于 laptop，而它同时是 k3s 节点、NFS 服务器和 libvirt 宿主，
# 即整个 lab 的单点；本地 state 也无法加锁，两次并发 apply 会悄悄写坏它。
#
# 为什么用 s3.lab.ddupan.top 而不是 obj.ddupan.top：公网名解析到 Cloudflare，要经 WAN 绕回。
# 2026-07-28 这条路被失效的 VPN 隧道黑洞了好几个小时。state 恰恰是故障期间要用的，必须在
# WAN 不通时也能访问。见 ../httproute-s3.yaml。
#
# backend 凭据是 tfstate 受限身份（AWS_* 环境变量，由 .gitea/scripts/tf.py 注入）；
# provider 用的是 s3-admin，见 main.tf。
terraform {
  backend "s3" {
    bucket                      = "tfstate"
    key                         = "seaweedfs/terraform.tfstate"
    endpoints                   = { s3 = "https://s3.lab.ddupan.top" }
    region                      = "us-east-1"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_lockfile                = true
  }
}
