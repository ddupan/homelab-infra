set interfaces ethernet eth0 address '192.168.10.2/24'
set interfaces ethernet eth0 description 'LAN / OSPF to NEC IX'
set interfaces ethernet eth0 hw-id 'bc:24:11:d6:4c:ac'
set interfaces ethernet eth0 offload gro
set interfaces ethernet eth0 offload gso
set interfaces ethernet eth0 offload sg
set interfaces ethernet eth0 offload tso
set interfaces ethernet eth1 address '10.60.0.1/24'
set interfaces ethernet eth1 description 'labnet VLAN100 gateway'
set interfaces ethernet eth1 hw-id 'bc:24:11:1b:d3:e9'
set interfaces ethernet eth1 offload gro
set interfaces ethernet eth1 offload gso
set interfaces ethernet eth1 offload sg
set interfaces ethernet eth1 offload tso
set interfaces ethernet eth2 address '10.61.0.1/24'
set interfaces ethernet eth2 description 'retronet VLAN110 gateway'
set interfaces ethernet eth2 hw-id 'bc:24:11:bd:3c:7a'
set interfaces ethernet eth2 offload gro
set interfaces ethernet eth2 offload gso
set interfaces ethernet eth2 offload sg
set interfaces ethernet eth2 offload tso
set interfaces loopback lo
set protocols ospf area 0 network '192.168.10.0/24'
set protocols ospf area 0 network '10.60.0.0/24'
set protocols ospf area 0 network '10.61.0.0/24'
set protocols ospf interface eth1 passive
set protocols ospf interface eth2 passive
set protocols ospf parameters router-id '192.168.10.2'
set protocols static route 0.0.0.0/0 next-hop 192.168.10.1
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 option default-router '10.60.0.1'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 option domain-name 'ad.ddupan.top'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 option name-server '192.168.10.5'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 range 0 start '10.60.0.100'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 range 0 stop '10.60.0.200'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 static-mapping retrolab ip-address '10.60.0.10'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 static-mapping retrolab mac 'bc:24:11:68:a0:51'
set service dhcp-server shared-network-name LABNET subnet 10.60.0.0/24 subnet-id '1'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 option default-router '10.61.0.1'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 option domain-name 'ad.ddupan.top'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 option name-server '192.168.10.5'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 option wins-server '10.61.0.5'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 range 0 start '10.61.0.100'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 range 0 stop '10.61.0.200'
set service dhcp-server shared-network-name RETRONET subnet 10.61.0.0/24 subnet-id '2'
set service ntp allow-client address '127.0.0.0/8'
set service ntp allow-client address '169.254.0.0/16'
set service ntp allow-client address '10.0.0.0/8'
set service ntp allow-client address '172.16.0.0/12'
set service ntp allow-client address '192.168.0.0/16'
set service ntp allow-client address '::1/128'
set service ntp allow-client address 'fe80::/10'
set service ntp allow-client address 'fc00::/7'
set service ntp server time1.vyos.net
set service ntp server time2.vyos.net
set service ntp server time3.vyos.net
set service ssh port '22'
set system config-management commit-revisions '100'
set system console device ttyS0 speed '115200'
set system host-name 'vyos-rtr'
set system login user vyos authentication encrypted-password '$6$rounds=656000$LrCooxAFgQ99.OkP$a5G8BnDrtoHl/8ZujgVIJr0z9aP.LZL35A1W8SXMnEDxT7eafT9Z3eoUD9jHBseIVuaqK2QpTMNg1YthCdDo..'
set system login user vyos authentication plaintext-password ''
set system login user vyos authentication public-keys laptop key 'AAAAC3NzaC1lZDI1NTE5AAAAIOLvzIxZhVRd9wEFWR/uCOx7b4HQEdPDiZd8LCN7Hics'
set system login user vyos authentication public-keys laptop type 'ssh-ed25519'
set system name-server '192.168.10.5'
set system option reboot-on-upgrade-failure '5'
set system syslog local facility all level 'info'
set system syslog local facility local7 level 'debug'