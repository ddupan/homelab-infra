#!/usr/bin/env bash
# Load every *.json in this folder into Grafana as a sidecar dashboard ConfigMap.
# The Grafana chart's dashboard sidecar (sidecar.dashboards.enabled) watches for
# ConfigMaps labeled grafana_dashboard=1 in the monitoring namespace and imports them.
# Idempotent — re-run after adding/updating a dashboard JSON.
#
# The VictoriaMetrics board uses a `$ds` datasource variable that resolves to the
# default datasource (VictoriaMetrics), so no per-panel rewiring is needed.
set -euo pipefail
cd "$(dirname "$0")"

NS=monitoring
for f in *.json; do
  [ -e "$f" ] || continue
  name="grafana-dashboard-$(basename "$f" .json)"
  echo "applying $name from $f"
  kubectl create configmap "$name" \
    --namespace "$NS" \
    --from-file="$f" \
    --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 --dry-run=client -o yaml \
  | kubectl apply -f -
done
