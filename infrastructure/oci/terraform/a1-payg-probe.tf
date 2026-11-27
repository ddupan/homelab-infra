# 临时探针：验证 PAYG 账户的 A1 免费额度是否仍为 4 OCPU / 24 GB。
# 2026-11 前从未在减半（传闻 2026-08 执行）后超过 2/12，Usage API 历史回答不了这个问题。
# 方法：与 homelab-vm 合计跑满 4/24 一到两天，看 cloud_cost_month_to_date{provider="oci",service="Compute"}
# 是否离开 0（Usage API 延迟数小时到一天）。得出结论后删除本文件，并按结论改回或保留 quota.tf。
#
# 不需要登录、不跑任何服务：无公网 IP，空闲实例即可产生 A1 用量。
# 启动盘 50 GB（Ubuntu 镜像最小 47 GB）：与现有 100 + 50 合计正好 200 GB 免费存储，不额外计费。
resource "oci_core_instance" "a1_payg_probe" {
  availability_domain = oci_core_instance.vm.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "a1-payg-probe"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = false
    display_name     = "a1-payg-probe"
  }

  metadata = {
    ssh_authorized_keys = var.instance_metadata["ssh_authorized_keys"]
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = 50
    boot_volume_vpus_per_gb = 10
  }
}
