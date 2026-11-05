# etcd-pve3 (LXC 152 on pve3): replaces the laptop's etcd member (#570).
# homelab_data::etcd installs the member and issues its certificates, but the unit stays
# stopped until the join runbook (infrastructure/etcd/README.md) has run `member add`
# and placed /etc/homelab-etcd/join. Maintenance metrics follow once it has joined and
# taken a snapshot; before that they would only report a missing backup.
name 'etcd-pve3'
run_list 'homelab_base::default', 'homelab_data::etcd'
%w(homelab_base homelab_data).each do |name|
  cookbook name,
           git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
           tag: 'v0.4.11',
           rel: "cookbooks/#{name}"
end

# The joining member's initial-cluster must list the cluster as it is after `member add`,
# etcd-laptop included; it is read only on that first start. Removing etcd-laptop later
# changes etcd.yml, so etcd-pve3 reports a pending (harmless) restart until restarted.
default['homelab_data']['etcd']['members'] = {
  'etcd-laptop' => '192.168.10.127',
  'etcd-pve1' => '10.60.0.20',
  'etcd-pve2' => '10.60.0.21',
  'etcd-pve3' => '10.60.0.22',
}
