locals {
  wireguard_home_prefixes = ["192.168.10.0/24", "10.60.0.0/24", "10.61.0.0/24"]
}

# route table -> subnet -> instance 已存在依赖，不能反向引用实例的私有 IP。
# 此值从现有 AMD VNIC 核对；重建实例后必须重新查询，禁止继续使用旧 OCID。
variable "amd_router_private_ip_ocid" {
  type    = string
  default = "ocid1.privateip.oc1.ap-osaka-1.abvwsljrhxq2cw46zhjyrnn5zbz4rrynjbzlynkz6ubhiedadr72zcaideaq"
}

resource "oci_core_network_security_group" "wireguard" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.vcn.id
  display_name   = "homelab-amd-wireguard"
}

resource "oci_core_network_security_group_security_rule" "wireguard" {
  network_security_group_id = oci_core_network_security_group.wireguard.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "WireGuard NAT traversal; peer public key authenticates clients"
  udp_options {
    destination_port_range {
      min = 51820
      max = 51820
    }
  }
}

resource "oci_core_network_security_group_security_rule" "dn42_first_peer" {
  network_security_group_id = oci_core_network_security_group.wireguard.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "DN42 first external WireGuard peer; public key authentication"
  udp_options {
    destination_port_range {
      min = 51821
      max = 51821
    }
  }
}

# oci-arm reaches the LAN via AMD (the VCN route to the home prefixes points at AMD's VNIC), so
# its packets must pass AMD's ingress filter with their real destination port. Without this only
# TCP 22 got through (the security list's 0.0.0.0/0 rule): spire-agent (.127:8081), Bao (.8:8200)
# and lab DNS (.127:53) were silently dropped. Mirrors the "WireGuard routed homelab traffic"
# rule for the opposite direction; scoped to oci-arm's NSG rather than the whole subnet.
resource "oci_core_network_security_group_security_rule" "arm_routed_home" {
  network_security_group_id = oci_core_network_security_group.wireguard.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.gitea.id
  source_type               = "NETWORK_SECURITY_GROUP"
  stateless                 = false
  description               = "oci-arm traffic routed home via AMD"
}
