#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="gpu-operator"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install NVIDIA GPU Operator on an existing Kubernetes cluster with GPU nodes.
Deploys Node Feature Discovery (NFD), container toolkit, and device plugin.
Uses host NVIDIA driver (containerized driver disabled) and CDI for device injection.

Options:
  --version VERSION   GPU Operator Helm chart version (default: latest)
  --dry-run           Print commands without executing
  --help              Show this help
EOF
    exit "${1:-0}"
}

VERSION=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help)    usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# Verify cluster access
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
fi

# Verify Helm is available
if ! command -v helm >/dev/null 2>&1; then
    echo "Error: helm not found. Install it first: https://helm.sh/docs/intro/install/" >&2
    exit 1
fi

# Add/update Helm repo
echo "-> Configuring Helm repo..."
if helm repo list 2>/dev/null | grep -q '^nvidia\b'; then
    helm repo update nvidia
else
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
fi

# Build version args
VERSION_ARGS=()
[[ -n "$VERSION" ]] && VERSION_ARGS=(--version "$VERSION")

if $DRY_RUN; then
    echo "DRY-RUN: helm upgrade --install gpu-operator nvidia/gpu-operator \\"
    echo "  --namespace ${NAMESPACE} --create-namespace \\"
    echo "  ${VERSION_ARGS[*]:-} -f ${SCRIPT_DIR}/values.yaml"
    exit 0
fi

echo "-> Deploying NVIDIA GPU Operator${VERSION:+ (version: ${VERSION})} to namespace: ${NAMESPACE}..."
helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    "${VERSION_ARGS[@]}" \
    -f "${SCRIPT_DIR}/values.yaml"

echo ""
echo "NVIDIA GPU Operator deployed."
echo "Run 'kubectl get pods -n ${NAMESPACE} -o wide' to verify."
echo "GPU nodes (only) should run nvidia-container-toolkit-daemonset and nvidia-device-plugin pods."
