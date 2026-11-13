# 云端池的 Actions cache 服务，platform/dynamic-runner/cache-server.yaml 的云端版本：runner 直接用
# GCS 时，一次性 executor 启动后要先把 bucket 里的 metadata 全部导入本地索引，查找不等它，
# job 开头的 restore 几乎必然 miss。这里常驻一个 `gitea-runner cache-server`。
#
# Always Free：us-central1 的一台 e2-micro 和 30 GB pd-standard。没有外网 IP（外网 IP 不在免费额度内）：
# 镜像经 Artifact Registry 远程仓库拉取，走子网的 Private Google Access。Pod 跨可用区访问它按
# 区域内流量计费（$0.01/GB），缓存量下可忽略。

locals {
  cache_server_zone = "${var.region}-a"
  cache_server_port = 8088
  # 与 executor 镜像里的官方 runner 同一版本（gitea-dynamic-runner container/runner.Dockerfile）。
  cache_server_image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.dockerhub.repository_id}/gitea/runner:6.0.0@sha256:f9a1f17484398b861c25a763b81febfb394b17b72e0522c25d8067d7b484f347"
}

# 节点不能直连 Docker Hub（没有外网 IP），同 ghcr 远程仓库。
resource "google_artifact_registry_repository" "dockerhub" {
  repository_id = "dockerhub"
  location      = var.region
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  # 免费额度只有 0.5 GB（与 ghcr 共用）。删掉后下次拉取会重新回源。
  cleanup_policy_dry_run = false
  cleanup_policies {
    id     = "expire-cached-images"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "7d"
    }
  }

  depends_on = [google_project_service.this]
}

resource "random_password" "cache_server_secret" {
  length  = 64
  special = false
}

resource "google_service_account" "cache_server" {
  account_id   = "gitea-runner-cache-server"
  display_name = "Gitea runner cache-server VM"

  depends_on = [google_project_service.this]
}

resource "google_artifact_registry_repository_iam_member" "cache_server_reader" {
  repository = google_artifact_registry_repository.dockerhub.name
  location   = google_artifact_registry_repository.dockerhub.location
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.cache_server.member
}

resource "google_compute_address" "cache_server" {
  name         = "gitea-runner-cache"
  address_type = "INTERNAL"
  subnetwork   = "default"
  region       = var.region
}

resource "google_compute_instance" "cache_server" {
  name         = "gitea-runner-cache"
  zone         = local.cache_server_zone
  machine_type = "e2-micro"
  tags         = ["gitea-runner-cache"]

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = "default"
    network_ip = google_compute_address.cache_server.address
    # 不配 access_config：没有外网 IP。
  }

  service_account {
    email  = google_service_account.cache_server.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    # COS 每次开机都重跑 cloud-init，/etc 下的文件随之重建；缓存数据在 stateful 分区。
    user-data = <<-EOT
      #cloud-config
      write_files:
        - path: /etc/gitea-runner-cache/config.yaml
          permissions: "0644"
          content: |
            log:
              level: info
            cache:
              dir: /data
              port: ${local.cache_server_port}
              external_secret_file: /etc/gitea-runner-cache/secret
              retention: 168h
              repo_size_limit: 10GB
              # 30 GB 盘扣掉 COS 自身和镜像。
              size_limit: 15GB
        - path: /etc/gitea-runner-cache/secret
          permissions: "0644"
          content: ${random_password.cache_server_secret.result}
        - path: /etc/systemd/system/gitea-runner-cache.service
          permissions: "0644"
          content: |
            [Unit]
            Wants=gcr-online.target network-online.target
            After=gcr-online.target network-online.target
            [Service]
            Environment=HOME=/home/gitea-runner-cache
            ExecStartPre=/bin/mkdir -p /home/gitea-runner-cache /mnt/stateful_partition/gitea-runner-cache
            ExecStartPre=/usr/bin/docker-credential-gcr configure-docker --registries=${var.region}-docker.pkg.dev
            ExecStartPre=-/usr/bin/docker rm -f gitea-runner-cache
            ExecStart=/usr/bin/docker run --rm --name gitea-runner-cache --network host \
              --user 0 --entrypoint /usr/local/bin/gitea-runner \
              -v /etc/gitea-runner-cache:/etc/gitea-runner-cache:ro \
              -v /mnt/stateful_partition/gitea-runner-cache:/data \
              ${local.cache_server_image} cache-server -c /etc/gitea-runner-cache/config.yaml
            ExecStop=/usr/bin/docker stop gitea-runner-cache
            Restart=always
            RestartSec=10
            [Install]
            WantedBy=multi-user.target
      runcmd:
        - systemctl daemon-reload
        - systemctl start gitea-runner-cache.service
    EOT
  }

  depends_on = [google_artifact_registry_repository_iam_member.cache_server_reader]
}

# GKE 的 Pod 网段不在 default 网络的 default-allow-internal（10.128.0.0/9）里。
resource "google_compute_firewall" "cache_server" {
  name          = "allow-gke-pods-to-gitea-runner-cache"
  network       = "default"
  source_ranges = [google_container_cluster.ci.cluster_ipv4_cidr]
  target_tags   = ["gitea-runner-cache"]

  allow {
    protocol = "tcp"
    ports    = [tostring(local.cache_server_port)]
  }
}
