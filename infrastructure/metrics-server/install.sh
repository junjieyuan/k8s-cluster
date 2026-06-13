#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="kube-system"
CHART_REPO="https://kubernetes-sigs.github.io/metrics-server"
CHART_NAME="metrics-server/metrics-server"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-3.13.1}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install metrics-server (via Helm) for kubectl top and HPA support.

Options:
  --version VERSION   Metrics Server chart version (default: 3.13.1)
  --dry-run           Print resources without applying
  --help              Show this help
EOF
    exit "${1:-0}"
}

VERSION="${METRICS_SERVER_VERSION}"
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
    echo "DRY-RUN: helm upgrade --install metrics-server ${CHART_NAME} \\"
    echo "  --namespace \"${NAMESPACE}\" \\"
    echo "  --version \"${VERSION}\" \\"
    echo "  -f \"${SCRIPT_DIR}/values.yaml\" \\"
    echo "  --wait \\"
    echo "  --timeout 5m"
    exit 0
fi

echo "-> Configuring Helm repo..."
if ! helm repo list -o yaml 2>/dev/null | grep -q "https://kubernetes-sigs.github.io/metrics-server"; then
    helm repo add metrics-server "${CHART_REPO}"
fi
helm repo update metrics-server

echo "-> Deploying metrics-server (chart: ${VERSION})..."
helm upgrade --install metrics-server "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --version "${VERSION}" \
    -f "${SCRIPT_DIR}/values.yaml" \
    --wait \
    --timeout 5m

echo ""
echo "metrics-server deployed."
echo "Verify: kubectl top nodes"
echo "        kubectl top pods -A"
echo "        kubectl -n ${NAMESPACE} logs deployment/metrics-server"
