# The AI gateway key UI (apps/ai-gateway/keys-ui.yaml, repo panxiao81/ai-gateway-keys).
# One KV secret per key under kv/k8s/ai-gateway-keys/<id>; ESO hands the active ones to
# the gateway. The app writes keys but never needs to read one back: a key is shown once at
# creation, so there is no "read" on data/ at all.
path "kv/data/k8s/ai-gateway-keys/*" {
  capabilities = ["create"]
}

# created_time + custom_metadata (status/created_by/description), the list, and revoke:
# DELETE on metadata removes the key and all its versions. Who revoked what is in the app's
# audit log line and Bao's audit log, not kept in KV.
path "kv/metadata/k8s/ai-gateway-keys/*" {
  capabilities = ["create", "update", "read", "list", "delete"]
}
