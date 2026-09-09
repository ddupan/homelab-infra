#!/usr/bin/env bash
# Install / upgrade the VictoriaMetrics operator into the monitoring namespace.
# The operator owns the VM* + VLSingle CRDs that everything else in this folder relies on.
set -euo pipefail

kubectl apply -f ../namespace.yaml

helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update vm

# Pin the chart version after the first install for reproducibility:
#   helm search repo vm/victoria-metrics-operator --versions | head
# then add:  --version <x.y.z>
helm upgrade --install vm-operator vm/victoria-metrics-operator \
  --namespace monitoring \
  --values values.yaml \
  --wait

# CRDs land cluster-wide; verify:
#   kubectl get crd | grep victoriametrics
