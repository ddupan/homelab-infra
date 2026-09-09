#!/usr/bin/env bash
# Deploy tracing: VictoriaTraces (VTSingle CR, operator-managed) + the OpenTelemetry
# Collector that fronts it. Apps send OTLP to otel-collector.monitoring.svc:4317 (gRPC)
# / :4318 (HTTP); the collector batches and forwards to VictoriaTraces.
#
# NOTE: we use the operator's VTSingle CRD (traces/vtsingle.yaml) rather than the
# victoria-traces-single Helm chart — one operator manages metrics, logs, and traces.
# traces-values.yaml is kept only as a reference for the standalone-chart alternative.
set -euo pipefail

kubectl apply -f vtsingle.yaml
kubectl -n monitoring wait --for=jsonpath='{.status.updateStatus}'=operational vtsingle/main --timeout=120s || true
kubectl apply -f otel-collector.yaml
