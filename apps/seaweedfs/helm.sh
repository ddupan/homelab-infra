#!/usr/bin/env bash

set -euo pipefail

helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install seaweedfs seaweedfs/seaweedfs \
  --namespace seaweedfs \
  --create-namespace \
  -f "$(dirname "$0")/values.yaml" \
  --wait
