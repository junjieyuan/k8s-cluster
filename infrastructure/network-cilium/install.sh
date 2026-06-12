#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install Cilium CNI on an initialized Kubernetes cluster.
Auto-downloads the cilium CLI if not already installed.
Enables Gateway API, kube-proxy replacement, and LB-IPAM by default.

Options:
  --version VERSION   Cilium version (default: 1.19.4)
  --cidr CIDR         Pod IPv4 CIDR (default: 172.16.0.0/12)
  --lb-cidr CIDR      LB-IPAM pool CIDR (default: auto-detect from node network)
  --dry-run           Print commands without executing
  --help              Show this help
EOF
    exit "${1:-0}"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="1.19.4"
CIDR="172.16.0.0/12"
LB_CIDR=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --cidr)    CIDR="$2";    shift 2 ;;
        --lb-cidr) LB_CIDR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help)    usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# Install cilium CLI if missing
if ! command -v cilium >/dev/null 2>&1; then
    if [[ $EUID -ne 0 ]]; then
        exec sudo "$0" "$@"
    fi
    echo "cilium CLI not found — installing..." >&2

    CLI_ARCH="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && CLI_ARCH="arm64"

    CLI_VERSION=$(curl -sSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_VERSION="${CLI_VERSION#v}"
    TARBALL="cilium-linux-${CLI_ARCH}.tar.gz"
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    echo "  Downloading cilium-cli v${CLI_VERSION} (${CLI_ARCH})..." >&2
    curl -sSfL \
        -o "$TMPDIR/$TARBALL" \
        "https://github.com/cilium/cilium-cli/releases/download/v${CLI_VERSION}/${TARBALL}"
    curl -sSfL \
        -o "$TMPDIR/${TARBALL}.sha256sum" \
        "https://github.com/cilium/cilium-cli/releases/download/v${CLI_VERSION}/${TARBALL}.sha256sum"

    echo "  Verifying checksum..." >&2
    (cd "$TMPDIR" && sha256sum --check "${TARBALL}.sha256sum")

    echo "  Installing to /usr/local/bin..." >&2
    tar xzvfC "$TMPDIR/$TARBALL" /usr/local/bin >/dev/null

    echo "  cilium CLI v${CLI_VERSION} installed" >&2
fi

# Verify cluster access
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
fi

# Auto-detect LB CIDR from node network if not provided
if [[ -z "$LB_CIDR" ]]; then
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -n "$NODE_IP" ]]; then
        # Derive the /24 subnet from the node IP
        LB_CIDR="${NODE_IP%.*}.0/24"
        echo "Auto-detected LB CIDR from node IP ${NODE_IP}: ${LB_CIDR}" >&2
    else
        echo "Error: cannot auto-detect LB CIDR. Provide --lb-cidr manually." >&2
        exit 1
    fi
fi

if $DRY_RUN; then
    echo "DRY-RUN: cilium install --version $VERSION \\"
    echo "  --set ipam.operator.clusterPoolIPv4PodCIDRList='{$CIDR}' \\"
    echo "  --set kubeProxyReplacement=true \\"
    echo "  --set gatewayAPI.enabled=true"
    echo ""
    echo "DRY-RUN: kubectl apply LB-IPAM pool with CIDR ${LB_CIDR}"
    exit 0
fi

echo "Installing Cilium $VERSION (Gateway API + kube-proxy replacement)..." >&2
cilium install --version "$VERSION" \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={$CIDR}" \
    --set kubeProxyReplacement=true \
    --set gatewayAPI.enabled=true
echo "Cilium installed." >&2

# Apply LB-IPAM pool
echo "Configuring LB-IPAM pool (CIDR: ${LB_CIDR})..." >&2
export LB_CIDR
envsubst '$LB_CIDR' < "${SCRIPT_DIR}/loadbalancer-ippool.yaml" | kubectl apply -f -
echo "LB-IPAM pool configured." >&2
