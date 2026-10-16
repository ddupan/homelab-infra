locals {
  proxy_http_client = {
    auto_block = true
    blocked    = false
  }

  proxy_negative_cache = {
    enabled      = true
    time_to_live = 60
  }

  oci_path_routing = {
    v1_enabled       = false
    force_basic_auth = false
    path_enabled     = true
  }

  repository_storage = {
    blob_store_name                = "default"
    strict_content_type_validation = true
  }
}

resource "sonatyperepo_repository_ansiblegalaxy_proxy" "galaxy" {
  name   = "ansible-galaxy-proxy"
  online = true

  http_client    = local.proxy_http_client
  negative_cache = local.proxy_negative_cache
  proxy = {
    remote_url       = "https://galaxy.ansible.com"
    content_max_age  = 1440
    metadata_max_age = 60
  }
  storage = local.repository_storage
}

resource "sonatyperepo_repository_ansiblegalaxy_group" "public" {
  name   = "ansible-public"
  online = true

  group = {
    member_names = [sonatyperepo_repository_ansiblegalaxy_proxy.galaxy.name]
  }
  storage = local.repository_storage
}

resource "sonatyperepo_repository_go_proxy" "public" {
  name   = "go-proxy"
  online = true

  http_client    = local.proxy_http_client
  negative_cache = local.proxy_negative_cache
  proxy = {
    remote_url       = "https://proxy.golang.org"
    content_max_age  = 1440
    metadata_max_age = 60
  }
  storage = local.repository_storage
}

resource "sonatyperepo_repository_go_group" "public" {
  name   = "go-public"
  online = true

  group = {
    member_names = [sonatyperepo_repository_go_proxy.public.name]
  }
  storage = local.repository_storage
}
