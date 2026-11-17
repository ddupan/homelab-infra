# Ayatori LoadBalancer hosts, dev. Deploy-time values live here, not in the cookbook:
# the drift timer why-runs against the last applied policy, so the policy is the record.
# Addresses, AS and VIP pool come from infrastructure/network/ipam.yml.
name 'loadbalancer-dev'
run_list 'homelab_base::default', 'homelab_loadbalancer::default'
# 按 cookbook 自己的版本从 Gitea Chef registry 取（homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://git.ddupan.top/api/packages/panxiao81/chef/api/v1'
cookbook 'homelab_base', '= 0.4.5'
cookbook 'homelab_loadbalancer', '= 0.4.3'

default['homelab_loadbalancer']['environment'] = 'dev'
# SHA-512 crypt of kv/infra/loadbalancer/dev password (Ayatori sends the plaintext).
# Not load-bearing: dataplaneapi skips Basic once the client certificate verifies, and
# the password is random; the cookbook's InSpec suite fails if that ever changes.
default['homelab_loadbalancer']['dataplaneapi']['password_hash'] = '$6$MF/KsEARVNZF4Vl2$FC3mfMQnry2uzPdniarOoSncWxR4cFRh9Yrq2/OY3BWnLpjbQg2oD03WiUANMcJRCoKbeRJ6o0lbjJ80XbQHB0'
# The Ayatori release whose lb-agent announces the VIPs here (cookbooks 0.4.7+).
default['homelab_loadbalancer']['agent']['version'] = '0.4.0'
# Ayatori ADR-0025：agent 被杀或崩溃时路由器保留本机路径至多 30s；Cinc 以 SIGKILL 重启 agent。
# 要大于 systemd 的 RestartSec（5s）加启动时间；需要认识该键的 agent（0.4.0+）。
default['homelab_loadbalancer']['agent']['graceful_restart_time'] = '30s'
# ADR-0022：agent 以节点身份加入控制面（首次签发见 ../ansible/join.yml），经本机 loopback 上的
# Data Plane API 收敛 HAProxy。与 policies/ayatori-dev.rb 的 agent_convergence 一起按环境切换。
default['homelab_loadbalancer']['agent']['join'] = true
default['homelab_loadbalancer']['agent']['converge'] = true
default['homelab_loadbalancer']['bgp']['local_as'] = 65101
# VyOS on labnet; it faces internal peers as AS 65002 (local-as), never its dn42 AS.
default['homelab_loadbalancer']['bgp']['neighbors'] = { '10.60.0.1' => 65002 }
default['homelab_loadbalancer']['bgp']['vip_pool'] = '10.62.1.0/24'
