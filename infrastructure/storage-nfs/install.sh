#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="kube-system"
CHART_REPO="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
CHART_NAME="csi-driver-nfs/csi-driver-nfs"
CSI_NFS_VERSION="${CSI_NFS_VERSION:-4.13.2}"
NFS_SERVER="${NFS_SERVER:-storage-001.k8s.junjie.pro}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy csi-driver-nfs via Helm and apply the NFS StorageClass.

Options:
  --server HOSTNAME     NFS server address (default: storage-001.k8s.junjie.pro)
  --version VERSION     CSI driver Helm chart version (default: 4.13.2)
  --dry-run             Print commands without executing
  --help                Show this help
EOF
    exit "${1:-0}"
}

VERSION="${CSI_NFS_VERSION}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)  NFS_SERVER="$2"; shift 2 ;;
        --version) VERSION="$2";    shift 2 ;;
        --dry-run) DRY_RUN=true;   shift ;;
        --help)    usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
    echo "Error: helm not found. Install it first: https://helm.sh/docs/intro/install/" >&2
    exit 1
fi

if $DRY_RUN; then
    echo "DRY-RUN: helm upgrade --install csi-driver-nfs ${CHART_NAME} \\"
    echo "  --namespace \"${NAMESPACE}\" \\"
    echo "  --create-namespace \\"
    echo "  --version \"${VERSION}\" \\"
    echo "  --wait \\"
    echo "  --timeout 5m"
    exit 0
fi

echo "-> Configuring Helm repo..."
if ! helm repo list -o yaml 2>/dev/null | grep -q "${CHART_REPO}"; then
    helm repo add csi-driver-nfs "${CHART_REPO}"
fi
helm repo update csi-driver-nfs

echo "-> Deploying csi-driver-nfs (version: ${VERSION}) to namespace: ${NAMESPACE}..."
helm upgrade --install csi-driver-nfs "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${VERSION}" \
    --wait \
    --timeout 5m

echo "-> Creating/updating StorageClass (server: ${NFS_SERVER})..."
export NFS_SERVER
SC_YAML="$(mktemp)"
trap "rm -f \"$SC_YAML\"" EXIT
envsubst '$NFS_SERVER' < "${SCRIPT_DIR}/storage-class.yaml" > "$SC_YAML"
kubectl apply -f "$SC_YAML"
rm -f "$SC_YAML"

echo ""
echo "csi-driver-nfs deployed."
echo "  Chart:    ${CHART_NAME} ${VERSION}"
echo "  NFS server: ${NFS_SERVER}"
