# Every Linux node: homelab_base only. Node-specific policies add their own
# cookbooks on top. The lock (base.lock.json) pins the exact cookbook revision;
# regenerate it deliberately with `cinc install base.rb` (see README).
name 'base'
run_list 'homelab_base::default'
cookbook 'homelab_base',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.3.1',
         rel: 'cookbooks/homelab_base'
