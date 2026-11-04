# etcd-pve1 (LXC 150 on pve1): etcd member and the prod PostgreSQL replica.
# homelab_data replaces shared-data-monitoring's Ansible play here; etcd and PostgreSQL
# themselves are still deployed by infrastructure/etcd/ and shared-postgresql/.
name 'etcd-pve1'
run_list 'homelab_base::default', 'homelab_data::monitoring'
cookbook 'homelab_base',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.10',
         rel: 'cookbooks/homelab_base'
cookbook 'homelab_data',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.10',
         rel: 'cookbooks/homelab_data'

default['homelab_data']['postgresql_prod'] = true
