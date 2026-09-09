# Read-only access for the External Secrets Operator in k3s.
#
# Scoped to kv/k8s/* deliberately — ESO syncs Kubernetes Secrets and has no reason
# to see the SSH CA, the PKI, or any other KV path. This is narrower than the human
# `admin` policy, which is the point: the machine identity is less privileged than
# the person.
#
# KV v2 splits data from metadata: reads go to <mount>/data/<path>, and listing or
# checking existence goes to <mount>/metadata/<path>. ESO needs both — without
# metadata it cannot resolve `dataFrom.extract`.
path "kv/data/k8s/*" {
  capabilities = ["read"]
}

path "kv/metadata/k8s/*" {
  capabilities = ["read", "list"]
}
