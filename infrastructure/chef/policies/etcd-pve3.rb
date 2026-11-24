# etcd-pve3 (LXC 152 on pve3): replaces the laptop's etcd member (#570).
# homelab_data::etcd installs the member and issues its certificates; it joined the
# cluster through infrastructure/etcd/ansible/member-join.yml (2026-11-06).
name 'etcd-pve3'
run_list 'homelab_base::default', 'homelab_data::etcd', 'homelab_data::monitoring'
# 按 cookbook 自己的版本从静态 supermarket 取（SeaweedFS bucket，homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://s3.lab.ddupan.top/chef-supermarket'
cookbook 'homelab_base', '= 0.4.6'
cookbook 'homelab_data', '= 0.2.2'

# The joining member's initial-cluster must list the cluster as it is after `member add`,
# etcd-laptop included; it is read only on that first start. Removing etcd-laptop later
# changes etcd.yml, so etcd-pve3 reports a pending (harmless) restart until restarted.
default['homelab_data']['etcd']['members'] = {
  'etcd-laptop' => '192.168.10.127',
  'etcd-pve1' => '10.60.0.20',
  'etcd-pve2' => '10.60.0.21',
  'etcd-pve3' => '10.60.0.22',
}
