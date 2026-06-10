#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="kube-system"
CHART_VERSION="4.13.2"

echo "=================================================="
echo "Deploying platform infrastructure: csi-driver-nfs"
echo "=================================================="

# Register and update Helm repo
echo "-> Configuring Helm repo..."
if helm repo list 2>/dev/null | grep -q '^csi-driver-nfs\b'; then
    helm repo update csi-driver-nfs
else
    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
fi

# Install/upgrade the driver
echo "-> Deploying csi-driver-nfs (version: ${CHART_VERSION}) to namespace: ${NAMESPACE}..."
helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}"

# Apply the associated StorageClass
echo "-> Creating/updating StorageClass..."
kubectl apply -f "${SCRIPT_DIR}/storage-class.yaml"

echo "=================================================="
echo "csi-driver-nfs deployed successfully."
echo "=================================================="
