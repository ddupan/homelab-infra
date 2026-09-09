#!/usr/bin/env bash
# Deploy Grafana. Create the OIDC client secret first (see oidc-secret.yaml header),
# then install the chart. Requires the metrics/logs/traces backends to exist so the
# provisioned datasources resolve.
set -euo pipefail

# 1) OIDC client secret (edit oidc-secret.yaml, or create it imperatively — preferred).
kubectl apply -f oidc-secret.yaml

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

# Pin --version after the first install (helm search repo grafana/grafana --versions).
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  --values values.yaml \
  --wait

# The tailnet FQDN, once the tailscale operator assigns it:
#   kubectl -n monitoring get ingress grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Break-glass admin password:
#   kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
