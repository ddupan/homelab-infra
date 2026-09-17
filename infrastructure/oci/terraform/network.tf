resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  display_name   = "homelab-igw"
  enabled        = true
  vcn_id         = oci_core_vcn.vcn.id
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  display_name   = "homelab-public-rt"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
  dynamic "route_rules" {
    for_each = toset(local.wireguard_home_prefixes)
    content {
      destination       = route_rules.value
      destination_type  = "CIDR_BLOCK"
      network_entity_id = var.amd_router_private_ip_ocid
    }
  }
  vcn_id = oci_core_vcn.vcn.id
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  display_name   = "homelab-public-sl"
  egress_security_rules {
    description      = ""
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    stateless        = false
  }
  ingress_security_rules {
    description = ""
    icmp_options {
      code = 4
      type = 3
    }
    protocol    = "1"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false
  }
  ingress_security_rules {
    description = ""
    protocol    = "17"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false
    udp_options {
      max = 41641
      min = 41641
    }
  }
  ingress_security_rules {
    description = ""
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false
    tcp_options {
      max = 22
      min = 22
    }
  }
  # 内层源地址保持家中网段；OCI 安全列表须允许这些已路由的流量。
  dynamic "ingress_security_rules" {
    for_each = toset(local.wireguard_home_prefixes)
    content {
      protocol    = "all"
      source      = ingress_security_rules.value
      source_type = "CIDR_BLOCK"
      stateless   = false
      description = "WireGuard routed homelab traffic"
    }
  }
  vcn_id = oci_core_vcn.vcn.id
}

resource "oci_core_subnet" "public" {
  cidr_block                 = "10.0.0.0/24"
  compartment_id             = var.compartment_ocid
  dhcp_options_id            = oci_core_vcn.vcn.default_dhcp_options_id
  display_name               = "homelab-public-subnet"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  vcn_id                     = oci_core_vcn.vcn.id
}

resource "oci_core_vcn" "vcn" {
  cidr_blocks    = ["10.0.0.0/16"]
  compartment_id = var.compartment_ocid
  display_name   = "homelab-vcn"
  dns_label      = "homelab"
  is_ipv6enabled = false
}

