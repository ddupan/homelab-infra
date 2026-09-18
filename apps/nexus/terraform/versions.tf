terraform {
  required_version = ">= 1.11.0"

  required_providers {
    sonatyperepo = {
      source  = "sonatype-nexus-community/sonatyperepo"
      version = "1.17.0"
    }
  }
}

provider "sonatyperepo" {
  # NXRM_SERVER_URL, NXRM_SERVER_USERNAME and NXRM_SERVER_PASSWORD are injected
  # from OpenBao by CI.
  # Provider credentials must never be committed or placed in tfvars/state.
}
