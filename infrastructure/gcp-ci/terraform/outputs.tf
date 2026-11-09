output "cluster_endpoint" {
  value = google_container_cluster.ci.endpoint
}

output "cache_bucket" {
  value = google_storage_bucket.ci_cache.name
}

output "ghcr_mirror" {
  description = "Prefix that replaces ghcr.io in image references."
  value       = "${google_artifact_registry_repository.ghcr.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.ghcr.repository_id}"
}

output "project_number" {
  value = google_project.ci.number
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.spire.name
}

output "terraform_ci_service_account" {
  value = google_service_account.terraform_ci.email
}
