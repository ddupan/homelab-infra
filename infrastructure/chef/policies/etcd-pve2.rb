# etcd-pve2 (LXC 151 on pve2): etcd member and the pgBackRest repository.
# homelab_data replaces shared-data-monitoring's Ansible play here; etcd and PostgreSQL
# themselves are still deployed by infrastructure/etcd/ and shared-postgresql/.
name 'etcd-pve2'
run_list 'homelab_base::default', 'homelab_data::monitoring'
cookbook 'homelab_base',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.10',
         rel: 'cookbooks/homelab_base'
cookbook 'homelab_data',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.10',
         rel: 'cookbooks/homelab_data'

default['homelab_data']['pgbackrest_repository'] = true
