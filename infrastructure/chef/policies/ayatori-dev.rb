# Ayatori 控制面 dev（ayatori-dev LXC）。部署时的值在这里，不在 cookbook 里：漂移检查按最后
# 一次 apply 的 policy why-run，policy 就是记录。
name 'ayatori-dev'
# adopt 接管原 Ansible 部署（停用它的 node_exporter），必须在 homelab_base 之前。
run_list 'homelab_ayatori::adopt', 'homelab_base::default', 'homelab_ayatori::default'
# 按 cookbook 自己的版本从静态 supermarket 取（SeaweedFS bucket，homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://s3.lab.ddupan.top/chef-supermarket'
cookbook 'homelab_base', '= 0.4.6'
cookbook 'homelab_ayatori', '= 0.4.0'

default['homelab_ayatori']['environment'] = 'dev'
# Flux 跟随的 Ayatori release 与同一 release 的 manager 镜像（按 digest 固定）。
default['homelab_ayatori']['release'] = 'v0.5.0'
default['homelab_ayatori']['image'] = 'zot.lab.ddupan.top/panxiao81/ayatori-manager@sha256:57f8ca27614259921749cde82c8a1e36ae089ca6f1b856fa914e8893d5946fa4'
default['homelab_ayatori']['postgresql_instance'] = {
  'name' => 'homelab-dev',
  'host' => 'pg-dev.lab.ddupan.top',
  'port' => 5433,
}
default['homelab_ayatori']['gitops'] = {
  'url' => 'https://github.com/ddupan/homelab-infra.git',
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
# 人经 kubectl + kubelogin 用 iam-login 登录（Ayatori ADR-0016）。audiences 只有本环境的客户端
# （apps/iam-login/terraform/clients.tf 的 ayatori-dev），Prod 的 token 进不来；admin_groups 绑定 cluster-admin。
default['homelab_ayatori']['oidc'] = {
  'issuer' => 'https://sso.ddupan.top',
  'audiences' => ['ayatori-dev'],
  'admin_groups' => ['platform-admins'],
}
