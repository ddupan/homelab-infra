# Ayatori LoadBalancer hosts, prod. Deploy-time values live here, not in the cookbook:
# the drift timer why-runs against the last applied policy, so the policy is the record.
# Addresses, AS and VIP pool come from infrastructure/network/ipam.yml.
name 'loadbalancer-prod'
run_list 'homelab_base::default', 'homelab_loadbalancer::default'
%w(homelab_base homelab_loadbalancer).each do |name|
  cookbook name,
           git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
           tag: 'v0.4.2',
           rel: "cookbooks/#{name}"
end

default['homelab_loadbalancer']['environment'] = 'prod'
# SHA-512 crypt of kv/infra/loadbalancer/prod password (Ayatori sends the plaintext).
# Not load-bearing: dataplaneapi skips Basic once the client certificate verifies, and
# the password is random; the cookbook's InSpec suite fails if that ever changes.
default['homelab_loadbalancer']['dataplaneapi']['password_hash'] = '$6$A7APG0w/Kx2eRx0v$w6DF3h6tmiX0D/Oh41eLewRjh3AdYeRUw4d2T6832YSR/FMgqiDIL3PKGN9.d0cSTMDujDdFxtvppjU5vV56E0'
default['homelab_loadbalancer']['bgp']['local_as'] = 65100
# VyOS on labnet; it faces internal peers as AS 65002 (local-as), never its dn42 AS.
default['homelab_loadbalancer']['bgp']['neighbors'] = { '10.60.0.1' => 65002 }
default['homelab_loadbalancer']['bgp']['vip_pool'] = '10.62.0.0/24'
