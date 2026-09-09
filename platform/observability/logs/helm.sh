#!/usr/bin/env bash
# Deploy the pod-log collector (vlagent DaemonSet) that ships container logs to the
# VLSingle instance created by ./vlsingle.yaml. Apply vlsingle.yaml first.
set -euo pipefail

kubectl apply -f vlsingle.yaml

helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update vm

# Pin --version after the first install (helm search repo vm/victoria-logs-collector --versions).
helm upgrade --install victoria-logs-collector vm/victoria-logs-collector \
  --namespace monitoring \
  --values collector-values.yaml \
  --wait
