#!/usr/bin/env bash

set -euo pipefail

helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm >/dev/null 2>&1 || true
helm repo update >/dev/null
# Break-glass only — Flux owns this release (helmrelease.yaml). Keep --version in sync with it.
helm upgrade --install seaweedfs seaweedfs/seaweedfs \
  --version 4.22.0 \
  --namespace seaweedfs \
  --create-namespace \
  -f "$(dirname "$0")/values.yaml" \
  --wait
