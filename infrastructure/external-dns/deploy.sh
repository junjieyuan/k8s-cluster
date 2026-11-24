#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# charts/ accumulates one cache directory per version; applying them all
# applies in lexicographic, not version, order, so a stale CRD could win.
CHART_VERSION="$(sed -n 's/^[[:space:]]*version: "\([^"]*\)".*/\1/p' "$SCRIPT_DIR/kustomization.yaml" | head -1)"
if [[ -z "$CHART_VERSION" ]]; then
  echo "error: no chart version in $SCRIPT_DIR/kustomization.yaml" >&2
  exit 1
fi

# Render first: kustomize downloads the chart to charts/, which the CRD
# apply below reads from.
kubectl kustomize --enable-helm "$SCRIPT_DIR" >/dev/null

# The kustomize render omits the chart's crds/; apply them separately so
# the CRD version always matches the chart version.
kubectl apply -f "$SCRIPT_DIR/charts/external-dns-${CHART_VERSION}/external-dns/crds/"

# Deploy external-dns
kubectl kustomize --enable-helm "$SCRIPT_DIR" | kubectl apply -f -
