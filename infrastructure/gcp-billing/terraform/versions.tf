terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
    # Only for google_service_usage_consumer_quota_override.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.3"
    }
  }
}

provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}
