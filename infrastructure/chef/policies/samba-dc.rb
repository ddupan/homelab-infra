# Samba AD DC (dc1): homelab_base only. AD itself stays in infrastructure/samba-ad/
# (Ansible, ansible-vault secrets); this replaces samba-ad's monitoring-dc.yml.
name 'samba-dc'
run_list 'homelab_base::default'
cookbook 'homelab_base',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.9',
         rel: 'cookbooks/homelab_base'

# LAN only, as monitoring-dc did: vmagent scrapes 192.168.10.5:9100
# (platform/observability scrapes/samba-dc.yaml). Also pins sshd to it, so the
# ULA address no longer takes SSH.
default['homelab_base']['listen_address'] = '192.168.10.5'
