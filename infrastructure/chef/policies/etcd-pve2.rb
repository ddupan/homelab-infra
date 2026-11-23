# etcd-pve2 (LXC 151 on pve2): etcd member and the pgBackRest repository.
# homelab_data runs the etcd member (homelab_data::etcd) and the maintenance monitoring;
# PostgreSQL itself is still deployed by shared-postgresql/.
name 'etcd-pve2'
run_list 'homelab_base::default', 'homelab_data::etcd', 'homelab_data::monitoring'
# 按 cookbook 自己的版本从静态 supermarket 取（SeaweedFS bucket，homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://s3.lab.ddupan.top/chef-supermarket'
cookbook 'homelab_base', '= 0.4.5'
cookbook 'homelab_data', '= 0.2.0'

default['homelab_data']['pgbackrest_repository'] = true

# homelab_data::etcd 原地接管 infrastructure/etcd 的 Ansible 部署（路径相同），证书改由本机用
# SPIFFE 身份向 Bao 续签；原来的 laptop 续签控制端随 etcd-laptop 退出（#570）已不再续签。
# Cinc 不重启 etcd：etcd.yml 与 Ansible 渲染的不同时只报 restart pending，逐个成员手动重启。
default['homelab_data']['etcd']['members'] = {
  'etcd-pve1' => '10.60.0.20',
  'etcd-pve2' => '10.60.0.21',
  'etcd-pve3' => '10.60.0.22',
}
