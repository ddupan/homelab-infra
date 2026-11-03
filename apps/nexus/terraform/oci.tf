# OCI repositories. Path-based routing: anonymous pulls are
# nexus.lab.ddupan.top/oci-public/<namespace>/<image>:<tag> (official images under
# library/), authenticated pushes go to oci-hosted.

resource "sonatyperepo_repository_oci_hosted" "hosted" {
  name   = "oci-hosted"
  online = true

  oci = local.oci_path_routing
  storage = merge(local.repository_storage, {
    write_policy  = "ALLOW"
    latest_policy = false
  })
  component = { proprietary_components = false }
  cosign    = { enforcement = "NONE" }
}

resource "sonatyperepo_repository_oci_proxy" "docker_hub" {
  name   = "oci-proxy"
  online = true

  # Authenticated: Docker Hub rate-limits anonymous pulls per egress IP, which the
  # whole lab shares, and a limited upstream makes Nexus answer 404 even for images
  # it has cached. The account only needs to read public images.
  http_client = merge(local.proxy_http_client, {
    authentication = {
      type     = "username"
      username = var.dockerhub_username
      password = var.dockerhub_token
    }
  })
  negative_cache = local.proxy_negative_cache
  proxy = {
    remote_url       = "https://registry-1.docker.io"
    content_max_age  = 1440
    metadata_max_age = 60
  }
  oci = local.oci_path_routing
  oci_proxy = {
    index_type                  = "HUB"
    cache_foreign_layers        = false
    foreign_layer_url_whitelist = []
  }
  storage = local.repository_storage
  cosign  = { enforcement = "NONE" }
}

# ghcr.io 与 registry.k8s.io：CI 的 pod runner 不能直连它们（homelab-cookbooks 的 homelab_ayatori
# Kitchen 要拉 ESO、Flux、kube-state-metrics），经 oci-public 组拉取。镜像都按 digest 引用，
# 组内成员同名镜像不会混淆。匿名拉取不限流，不需要账号。
resource "sonatyperepo_repository_oci_proxy" "ghcr" {
  name   = "oci-proxy-ghcr"
  online = true

  http_client    = local.proxy_http_client
  negative_cache = local.proxy_negative_cache
  proxy = {
    remote_url       = "https://ghcr.io"
    content_max_age  = 1440
    metadata_max_age = 60
  }
  oci = local.oci_path_routing
  oci_proxy = {
    index_type                  = "REGISTRY"
    cache_foreign_layers        = false
    foreign_layer_url_whitelist = []
  }
  storage = local.repository_storage
  cosign  = { enforcement = "NONE" }
}

resource "sonatyperepo_repository_oci_proxy" "k8s" {
  name   = "oci-proxy-k8s"
  online = true

  http_client    = local.proxy_http_client
  negative_cache = local.proxy_negative_cache
  proxy = {
    remote_url       = "https://registry.k8s.io"
    content_max_age  = 1440
    metadata_max_age = 60
  }
  oci = local.oci_path_routing
  oci_proxy = {
    index_type                  = "REGISTRY"
    cache_foreign_layers        = false
    foreign_layer_url_whitelist = []
  }
  storage = local.repository_storage
  cosign  = { enforcement = "NONE" }
}

resource "sonatyperepo_repository_oci_group" "public" {
  name   = "oci-public"
  online = true

  # Docker Hub 在前：没有 registry 前缀的镜像一直从这里来。
  group = { member_names = [
    sonatyperepo_repository_oci_proxy.docker_hub.name,
    sonatyperepo_repository_oci_proxy.ghcr.name,
    sonatyperepo_repository_oci_proxy.k8s.name,
  ] }
  oci     = local.oci_path_routing
  storage = local.repository_storage
  cosign  = { enforcement = "NONE" }
}

# Created by reconcile-oci.sh before the provider had OCI resources.
import {
  to = sonatyperepo_repository_oci_hosted.hosted
  id = "oci-hosted"
}

import {
  to = sonatyperepo_repository_oci_proxy.docker_hub
  id = "oci-proxy"
}

import {
  to = sonatyperepo_repository_oci_group.public
  id = "oci-public"
}
