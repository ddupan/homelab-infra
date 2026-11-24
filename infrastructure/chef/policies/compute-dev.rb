# Ayatori 计算节点 dev（compute-dev-1..3，PVE 上的 VM，见 ../../compute/）。先只有节点基线（SPIRE agent、
# Bao SSH CA 信任、监控）；Ayatori 发布含计算后端的 release 后再加 homelab_compute 与它的部署时值。
name 'compute-dev'
run_list 'homelab_base::default'
# 按 cookbook 自己的版本从静态 supermarket 取（SeaweedFS bucket，homelab-cookbooks README「发布」）。
default_source :supermarket, 'https://s3.lab.ddupan.top/chef-supermarket'
cookbook 'homelab_base', '= 0.4.6'
