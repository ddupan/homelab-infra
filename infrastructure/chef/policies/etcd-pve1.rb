# etcd-pve1 (LXC 150 on pve1): etcd member and the prod PostgreSQL replica.
# homelab_data replaces shared-data-monitoring's Ansible play here; etcd and PostgreSQL
# themselves are still deployed by infrastructure/etcd/ and shared-postgresql/.
name 'etcd-pve1'
run_list 'homelab_base::default', 'homelab_data::monitoring'
# 按 cookbook 自己的版本从 Gitea Chef registry 取（homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://git.ddupan.top/api/packages/panxiao81/chef/api/v1'
cookbook 'homelab_base', '= 0.4.5'
cookbook 'homelab_data', '= 0.2.0'

default['homelab_data']['postgresql_prod'] = true
