#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: cilium.sh [OPTIONS]

Install Cilium CNI on an initialized Kubernetes cluster.

Options:
  --version VERSION   Cilium version (default: 1.19.0)
  --cidr CIDR         Pod IPv4 CIDR (default: 172.16.0.0/12)
  --help              Show this help
EOF
    exit "${1:-0}"
}

VERSION="1.19.0"
CIDR="172.16.0.0/12"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --cidr)    CIDR="$2";    shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help)    usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

command -v cilium >/dev/null 2>&1 || {
    echo "Error: cilium CLI not found. Install it: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/" >&2
    exit 1
}

# Verify cluster access (cilium CLI needs a working kubeconfig)
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    echo "  Run: mkdir -p \$HOME/.kube && sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config && sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config" >&2
    exit 1
fi

if $DRY_RUN; then
    echo "DRY-RUN: cilium install --version $VERSION --set ipam.operator.clusterPoolIPv4PodCIDRList='{$CIDR}'"
    exit 0
fi

echo "Installing Cilium $VERSION with pod CIDR $CIDR..." >&2
cilium install --version "$VERSION" --set "ipam.operator.clusterPoolIPv4PodCIDRList={$CIDR}"
echo "Cilium installed." >&2
