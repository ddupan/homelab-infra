#!/usr/bin/env bash
# kube-state-metrics — metrics about k8s objects (deployments, pods, nodes, PVCs, ...).
# Its chart ships a ServiceMonitor; the VM operator's Prometheus converter turns that
# into a VMServiceScrape automatically, so no hand-written scrape CR is needed here.
#
# Prereq: the Prometheus-operator CRDs (ServiceMonitor, ...) must exist in the cluster
# for `serviceMonitor.enabled` to apply. If they don't:
#   kubectl apply --server-side -f \
#     https://github.com/prometheus-operator/prometheus-operator/releases/latest/download/bundle.yaml \
#     # (or just the monitoring.coreos.com CRDs)
# Alternatively, disable the ServiceMonitor below and add a VMServiceScrape by hand.
set -euo pipefail

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  --namespace monitoring \
  --set prometheus.monitor.enabled=true \
  --wait
