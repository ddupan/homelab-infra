# Samba AD DC (dc1): homelab_base only. AD itself stays in infrastructure/samba-ad/
# (Ansible, ansible-vault secrets); this replaces samba-ad's monitoring-dc.yml.
name 'samba-dc'
run_list 'homelab_base::default'
# 按 cookbook 自己的版本从静态 supermarket 取（SeaweedFS bucket，homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://s3.lab.ddupan.top/chef-supermarket'
cookbook 'homelab_base', '= 0.4.6'

# LAN only, as monitoring-dc did: vmagent scrapes 192.168.10.5:9100
# (platform/observability scrapes/samba-dc.yaml). Also pins sshd to it, so the
# ULA address no longer takes SSH.
default['homelab_base']['listen_address'] = '192.168.10.5'
