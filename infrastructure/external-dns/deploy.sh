#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kustomize downloads the chart to charts/, generating the cache.
# We need it first to apply CRDs from the cached chart directory.
kubectl kustomize --enable-helm "$SCRIPT_DIR" >/dev/null

# Apply DNSEndpoint CRD from the Helm chart's crds/ directory.
# This ensures the CRD version always matches the chart version.
kubectl apply -f "$SCRIPT_DIR/charts/external-dns-"*"/crds/"

# Deploy external-dns
kubectl kustomize --enable-helm "$SCRIPT_DIR" | kubectl apply -f -
