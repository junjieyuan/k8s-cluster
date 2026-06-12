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
    echo "DRY-RUN: install Gateway API CRDs v1.5.1"
    echo "DRY-RUN: patch TLSRoute CRD for v1alpha2 compatibility"
    echo "DRY-RUN: apply LB-IPAM pool (CIDR: ${LB_CIDR})"
    echo "DRY-RUN: enable L2 announcements + leases RBAC + L2AnnouncementPolicy"
    exit 0
fi

echo "Installing Cilium $VERSION (Gateway API + kube-proxy replacement)..." >&2
cilium install --version "$VERSION" \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={$CIDR}" \
    --set kubeProxyReplacement=true \
    --set gatewayAPI.enabled=true
echo "Cilium installed." >&2

# Install Gateway API CRDs (Cilium 1.19 requires v1.5.1 with v1alpha2 TLSRoute patch)
echo "Installing Gateway API CRDs..." >&2
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml

# Cilium 1.19 operator requires TLSRoute v1alpha2 (served=false in v1.5.1 CRD)
echo "Patching TLSRoute CRD for v1alpha2 compatibility..." >&2
kubectl patch crd tlsroutes.gateway.networking.k8s.io --type=json \
    -p='[{"op": "replace", "path": "/spec/versions/1/served", "value": true}]'

# Wait for operator to be ready
echo "Waiting for Cilium operator..." >&2
kubectl rollout status deploy/cilium-operator -n kube-system --timeout=120s

# Apply LB-IPAM pool + L2 announcements for external access
echo "Configuring LB-IPAM pool (CIDR: ${LB_CIDR})..." >&2
export LB_CIDR
envsubst '$LB_CIDR' < "${SCRIPT_DIR}/loadbalancer-ippool.yaml" | kubectl apply -f -

echo "Enabling L2 announcements for external LB access..." >&2
kubectl patch configmap cilium-config -n kube-system --type=json -p='[
  {"op": "add", "path": "/data/enable-l2-announcements", "value": "true"}
]'

# L2 announcements need leases RBAC (cilium upgrade does not add it)
echo "Adding leases RBAC for L2 announcements..." >&2
kubectl patch clusterrole cilium --type=json -p='[
  {"op": "add", "path": "/rules/-", "value": {"apiGroups": ["coordination.k8s.io"], "resources": ["leases"], "verbs": ["get","list","watch","create","update","delete"]}}
]' 2>/dev/null || true

kubectl apply -f "${SCRIPT_DIR}/l2-announcement-policy.yaml"

kubectl rollout restart ds/cilium -n kube-system
kubectl rollout status ds/cilium -n kube-system --timeout=120s
echo "LB-IPAM and L2 announcements configured." >&2
