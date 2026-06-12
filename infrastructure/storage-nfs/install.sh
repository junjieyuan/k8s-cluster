#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="kube-system"
CHART_VERSION="4.13.2"
NFS_SERVER="${NFS_SERVER:-storage-001.k8s.junjie.pro}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy csi-driver-nfs via Helm and apply the NFS StorageClass.

Options:
  --server HOSTNAME     NFS server address (default: storage-001.k8s.junjie.pro)
  --help                Show this help
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server) NFS_SERVER="$2"; shift 2 ;;
        --help)   usage 0 ;;
        *)        echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

echo "=================================================="
echo "Deploying platform infrastructure: csi-driver-nfs"
echo "=================================================="

echo "-> Configuring Helm repo..."
if helm repo list 2>/dev/null | grep -q '^csi-driver-nfs\b'; then
    helm repo update csi-driver-nfs
else
    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
fi

echo "-> Deploying csi-driver-nfs (version: ${CHART_VERSION}) to namespace: ${NAMESPACE}..."
helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}"

echo "-> Creating/updating StorageClass (server: ${NFS_SERVER})..."
export NFS_SERVER
SC_YAML="$(mktemp)"
trap "rm -f \"$SC_YAML\"" EXIT
envsubst '$NFS_SERVER' < "${SCRIPT_DIR}/storage-class.yaml" > "$SC_YAML"
kubectl apply -f "$SC_YAML"
rm -f "$SC_YAML"

echo "=================================================="
echo "csi-driver-nfs deployed successfully."
echo "=================================================="
