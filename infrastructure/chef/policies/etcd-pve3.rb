# etcd-pve3 (LXC 152 on pve3): replaces the laptop's etcd member (#570). Baseline only
# for now; homelab_data's etcd recipe and maintenance metrics come with the member swap.
name 'etcd-pve3'
run_list 'homelab_base::default'
cookbook 'homelab_base',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.10',
         rel: 'cookbooks/homelab_base'
