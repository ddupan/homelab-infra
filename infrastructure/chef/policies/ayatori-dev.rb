# Ayatori 控制面 dev（ayatori-dev LXC）。部署时的值在这里，不在 cookbook 里：漂移检查按最后
# 一次 apply 的 policy why-run，policy 就是记录。PostgreSQL、GitOps 与 LB 的值原在
# infrastructure/ayatori/ansible/inventory。
name 'ayatori-dev'
# adopt 接管原 Ansible 部署（停用它的 node_exporter），必须在 homelab_base 之前。
run_list 'homelab_ayatori::adopt', 'homelab_base::default', 'homelab_ayatori::default'
%w(homelab_base homelab_ayatori).each do |name|
  cookbook name,
           git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
           tag: 'v0.4.9',
           rel: "cookbooks/#{name}"
end

default['homelab_ayatori']['environment'] = 'dev'
# Flux 跟随的 Ayatori release；manager 镜像暂用 Ayatori PR #80 的构建（ADR-0021 客户端证书，
# 基于 v0.3.0-rc.1），PR 进入 release 后换成 release 镜像的 digest。
default['homelab_ayatori']['release'] = 'v0.3.0-rc.1'
default['homelab_ayatori']['image'] = 'zot.lab.ddupan.top/panxiao81/ayatori-manager@sha256:2299a3033e64f65f31d48994d0576a03dcd928da6d54b035b3684e41b6c00d33'
default['homelab_ayatori']['postgresql_instance'] = {
  'name' => 'homelab-dev',
  'host' => 'pg-dev.lab.ddupan.top',
  'hostaddr' => '192.168.10.127',
  'port' => 5433,
}
default['homelab_ayatori']['gitops'] = {
  'url' => 'https://git.ddupan.top/panxiao81/homelab-infra.git',
  'path' => './clusters/ayatori-dev',
}
# VIP 池见 infrastructure/network/ipam.yml；LB 主机在 clusters/ayatori-dev/loadbalancer-hosts.yaml。
default['homelab_ayatori']['loadbalancer']['address_pool'] = '10.62.1.0/24'
# Hostname 写入 Ayatori 独占的 zone（infrastructure/dns/terraform/lb-zones.tf）；API key 由 ESO 读取 Bao kv/k8s/powerdns。
default['homelab_ayatori']['loadbalancer']['dns'] = {
  'url' => 'http://192.168.10.127:8053',
  'zone' => 'dev-lb.lab.ddupan.top',
}
