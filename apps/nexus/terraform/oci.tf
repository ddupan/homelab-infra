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

resource "sonatyperepo_repository_oci_group" "public" {
  name   = "oci-public"
  online = true

  group   = { member_names = [sonatyperepo_repository_oci_proxy.docker_hub.name] }
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
