#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="gpu-operator"
CHART_REPO="https://helm.ngc.nvidia.com/nvidia"
CHART_NAME="nvidia/gpu-operator"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.3.3}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install NVIDIA GPU Operator on an existing Kubernetes cluster with GPU nodes.
Deploys Node Feature Discovery (NFD), container toolkit, and device plugin.
Uses host NVIDIA driver (containerized driver disabled) and CDI for device injection.

Options:
  --version VERSION   GPU Operator Helm chart version (default: v26.3.3)
  --dry-run           Print commands without executing
  --help              Show this help
EOF
    exit "${1:-0}"
}

VERSION="${GPU_OPERATOR_VERSION}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
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
    echo "DRY-RUN: helm upgrade --install gpu-operator ${CHART_NAME} \\"
    echo "  --namespace \"${NAMESPACE}\" \\"
    echo "  --create-namespace \\"
    echo "  --version \"${VERSION}\" \\"
    echo "  -f \"${SCRIPT_DIR}/values.yaml\" \\"
    echo "  --wait \\"
    echo "  --timeout 5m"
    exit 0
fi

echo "-> Configuring Helm repo..."
if ! helm repo list -o yaml 2>/dev/null | grep -q "${CHART_REPO}"; then
    helm repo add nvidia "${CHART_REPO}"
fi
helm repo update nvidia

echo "-> Deploying NVIDIA GPU Operator (version: ${VERSION}) to namespace: ${NAMESPACE}..."
helm upgrade --install gpu-operator "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${VERSION}" \
    -f "${SCRIPT_DIR}/values.yaml" \
    --wait \
    --timeout 5m

echo ""
echo "NVIDIA GPU Operator deployed."
echo "  Chart:   ${CHART_NAME} ${VERSION}"
echo "Verify: kubectl get pods -n ${NAMESPACE} -o wide"
echo "GPU nodes (only) should run nvidia-container-toolkit-daemonset and nvidia-device-plugin pods."
