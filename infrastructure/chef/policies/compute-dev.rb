# Ayatori 计算节点 dev（compute-dev-1..3，PVE 上的 VM，见 ../../compute/）。先只有节点基线（SPIRE agent、
# Bao SSH CA 信任、监控）；Ayatori 发布含计算后端的 release 后再加 homelab_compute 与它的部署时值。
name 'compute-dev'
run_list 'homelab_base::default'
cookbook 'homelab_base',
         git: 'https://git.ddupan.top/panxiao81/homelab-cookbooks.git',
         tag: 'v0.4.15',
         rel: 'cookbooks/homelab_base'
