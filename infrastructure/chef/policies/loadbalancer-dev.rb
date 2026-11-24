# Ayatori LoadBalancer hosts, dev. Deploy-time values live here, not in the cookbook:
# the drift timer why-runs against the last applied policy, so the policy is the record.
# Addresses, AS and VIP pool come from infrastructure/network/ipam.yml.
name 'loadbalancer-dev'
run_list 'homelab_base::default', 'homelab_loadbalancer::default'
# 按 cookbook 自己的版本从静态 supermarket 取（SeaweedFS bucket，homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://s3.lab.ddupan.top/chef-supermarket'
cookbook 'homelab_base', '= 0.4.6'
cookbook 'homelab_loadbalancer', '= 0.6.0'

# The Ayatori release whose lb-agent announces the VIPs here (cookbooks 0.4.7+).
default['homelab_loadbalancer']['agent']['version'] = '0.5.0'
# Ayatori ADR-0025：agent 被杀或崩溃时路由器保留本机路径至多 30s；Cinc 以 SIGKILL 重启 agent。
# 要大于 systemd 的 RestartSec（5s）加启动时间；需要认识该键的 agent（0.4.0+）。
default['homelab_loadbalancer']['agent']['graceful_restart_time'] = '30s'
# ADR-0022：agent 总是以节点身份加入控制面（首次签发见 ../ansible/join.yml），经本机 loopback
# 上的 Data Plane API 收敛 HAProxy（cookbook 0.5.0 起不再有开关）；与 policies/ayatori-dev.rb 的
# agent_convergence 配套。
default['homelab_loadbalancer']['bgp']['local_as'] = 65101
# VyOS on labnet; it faces internal peers as AS 65002 (local-as), never its dn42 AS.
default['homelab_loadbalancer']['bgp']['neighbors'] = { '10.60.0.1' => 65002 }
default['homelab_loadbalancer']['bgp']['vip_pool'] = '10.62.1.0/24'
