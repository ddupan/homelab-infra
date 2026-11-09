# Ayatori 控制面 prod（ayatori-prod LXC）。部署时的值在这里，不在 cookbook 里：漂移检查按最后
# 一次 apply 的 policy why-run，policy 就是记录。
name 'ayatori-prod'
# adopt 接管原 Ansible 部署（停用它的 node_exporter），必须在 homelab_base 之前。
run_list 'homelab_ayatori::adopt', 'homelab_base::default', 'homelab_ayatori::default'
%w(homelab_base homelab_ayatori).each do |name|
  cookbook name,
           git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
           tag: 'v0.4.14',
           rel: "cookbooks/#{name}"
end

default['homelab_ayatori']['environment'] = 'prod'
# Flux 跟随的 Ayatori release 与同一 release 的 manager 镜像（按 digest 固定）。只经 promotion 改为
# Dev（policies/ayatori-dev.rb）已验收的 release。
default['homelab_ayatori']['release'] = 'v0.3.1'
default['homelab_ayatori']['image'] = 'zot.lab.ddupan.top/panxiao81/ayatori-manager@sha256:fa57838cda328b14e6e90f934b17db520d35ab539d20db5e6521369cdd2863b5'
default['homelab_ayatori']['postgresql_instance'] = {
  'name' => 'homelab-prod',
  'host' => 'pg-prod.lab.ddupan.top',
  'port' => 5432,
}
default['homelab_ayatori']['gitops'] = {
  'url' => 'https://git.ddupan.top/panxiao81/homelab-infra.git',
  'path' => './clusters/ayatori-prod',
}
# VIP 池见 infrastructure/network/ipam.yml；LB 主机在 clusters/ayatori-prod/loadbalancer-hosts.yaml。
default['homelab_ayatori']['loadbalancer']['address_pool'] = '10.62.0.0/24'
# ADR-0022：节点 agent 加入控制面（首次签发见 ../ansible/join.yml）。
default['homelab_ayatori']['node_agents'] = true
# ADR-0022：LB 主机的 agent 自己收敛 HAProxy，manager 停止远端写入；随后 loadbalancer-prod 打开 agent.converge。
default['homelab_ayatori']['loadbalancer']['agent_convergence'] = true
# Hostname 写入 Ayatori 独占的 zone（infrastructure/dns/terraform/lb-zones.tf）；API key 由 ESO 读取 Bao kv/k8s/powerdns。
default['homelab_ayatori']['loadbalancer']['dns'] = {
  'url' => 'http://192.168.10.127:8053',
  'zone' => 'lb.lab.ddupan.top',
}
