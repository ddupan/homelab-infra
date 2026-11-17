# etcd-pve2 (LXC 151 on pve2): etcd member and the pgBackRest repository.
# homelab_data replaces shared-data-monitoring's Ansible play here; etcd and PostgreSQL
# themselves are still deployed by infrastructure/etcd/ and shared-postgresql/.
name 'etcd-pve2'
run_list 'homelab_base::default', 'homelab_data::monitoring'
# 按 cookbook 自己的版本从 Gitea Chef registry 取（homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://git.ddupan.top/api/packages/panxiao81/chef/api/v1'
cookbook 'homelab_base', '= 0.4.5'
cookbook 'homelab_data', '= 0.2.0'

default['homelab_data']['pgbackrest_repository'] = true
