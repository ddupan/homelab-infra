resource "oci_limits_quota" "free_tier_quota" {
  compartment_id = var.compartment_ocid
  description    = "Enforce Always Free tier compliance for compute and storage."
  name           = "always-free-tier-quota"
  statements     = ["set compute-core quota standard-a1-core-count to 4 in tenancy", "set compute-memory quota standard-a1-memory-count to 24 in tenancy", "set block-storage quota volume-count to 10 in tenancy", "set block-storage quota total-storage-gb to 200 in tenancy"]
}

