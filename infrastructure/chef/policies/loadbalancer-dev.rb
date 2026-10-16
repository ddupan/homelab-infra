# Ayatori LoadBalancer hosts, dev. Deploy-time values live here, not in the cookbook:
# the drift timer why-runs against the last applied policy, so the policy is the record.
# Addresses, AS and VIP pool come from infrastructure/network/ipam.yml.
name 'loadbalancer-dev'
run_list 'homelab_base::default', 'homelab_loadbalancer::default'
%w(homelab_base homelab_loadbalancer).each do |name|
  cookbook name,
           git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
           tag: 'v0.4.2',
           rel: "cookbooks/#{name}"
end

default['homelab_loadbalancer']['environment'] = 'dev'
# SHA-512 crypt of kv/infra/loadbalancer/dev password (Ayatori sends the plaintext).
# Not load-bearing: dataplaneapi skips Basic once the client certificate verifies, and
# the password is random; the cookbook's InSpec suite fails if that ever changes.
default['homelab_loadbalancer']['dataplaneapi']['password_hash'] = '$6$MF/KsEARVNZF4Vl2$FC3mfMQnry2uzPdniarOoSncWxR4cFRh9Yrq2/OY3BWnLpjbQg2oD03WiUANMcJRCoKbeRJ6o0lbjJ80XbQHB0'
default['homelab_loadbalancer']['bgp']['local_as'] = 65101
# VyOS on labnet; it faces internal peers as AS 65002 (local-as), never its dn42 AS.
default['homelab_loadbalancer']['bgp']['neighbors'] = { '10.60.0.1' => 65002 }
default['homelab_loadbalancer']['bgp']['vip_pool'] = '10.62.1.0/24'
