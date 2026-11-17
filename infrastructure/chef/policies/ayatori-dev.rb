# Ayatori 控制面 dev（ayatori-dev LXC）。部署时的值在这里，不在 cookbook 里：漂移检查按最后
# 一次 apply 的 policy why-run，policy 就是记录。
name 'ayatori-dev'
# adopt 接管原 Ansible 部署（停用它的 node_exporter），必须在 homelab_base 之前。
run_list 'homelab_ayatori::adopt', 'homelab_base::default', 'homelab_ayatori::default'
# 按 cookbook 自己的版本从 Gitea Chef registry 取（homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://git.ddupan.top/api/packages/panxiao81/chef/api/v1'
cookbook 'homelab_base', '= 0.4.5'
cookbook 'homelab_ayatori', '= 0.1.6'

default['homelab_ayatori']['environment'] = 'dev'
# Flux 跟随的 Ayatori release 与同一 release 的 manager 镜像（按 digest 固定）。
default['homelab_ayatori']['release'] = 'v0.4.0'
default['homelab_ayatori']['image'] = 'zot.lab.ddupan.top/panxiao81/ayatori-manager@sha256:8ec7f7b6deb62c7e26f95c881f0a3a7d34333fb79564fd23c1f51132d31409c9'
default['homelab_ayatori']['postgresql_instance'] = {
  'name' => 'homelab-dev',
  'host' => 'pg-dev.lab.ddupan.top',
  'port' => 5433,
}
default['homelab_ayatori']['gitops'] = {
  'url' => 'https://git.ddupan.top/panxiao81/homelab-infra.git',
  'path' => './clusters/ayatori-dev',
}
# VIP 池见 infrastructure/network/ipam.yml。LB 主机由各自的 agent 注册（ADR-0022），不在 GitOps 中声明。
default['homelab_ayatori']['loadbalancer']['address_pool'] = '10.62.1.0/24'
# ADR-0022：节点 agent 加入控制面（首次签发见 ../ansible/join.yml）；LB 主机在本机收敛，manager
# 只汇总报告。与 policies/loadbalancer-dev.rb 的 agent.converge 一起按环境切换。
default['homelab_ayatori']['node_agents'] = true
default['homelab_ayatori']['loadbalancer']['agent_convergence'] = true
# Hostname 写入 Ayatori 独占的 zone（infrastructure/dns/terraform/lb-zones.tf）；API key 由 ESO 读取 Bao kv/k8s/powerdns。
default['homelab_ayatori']['loadbalancer']['dns'] = {
  'url' => 'http://192.168.10.127:8053',
  'zone' => 'dev-lb.lab.ddupan.top',
}
