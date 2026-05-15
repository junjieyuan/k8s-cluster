#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: cilium.sh [OPTIONS]

Install Cilium CNI on an initialized Kubernetes cluster.
Auto-downloads the cilium CLI if not already installed.

Options:
  --version VERSION   Cilium version (default: 1.19.4)
  --cidr CIDR         Pod IPv4 CIDR (default: 172.16.0.0/12)
  --dry-run           Print commands without executing
  --help              Show this help
EOF
    exit "${1:-0}"
}

VERSION="1.19.4"
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

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Install cilium CLI if missing
if ! command -v cilium >/dev/null 2>&1; then
    echo "cilium CLI not found — installing..." >&2

    CLI_ARCH="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && CLI_ARCH="arm64"

    CLI_VERSION=$(curl -sSf https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
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
    $SUDO tar xzvfC "$TMPDIR/$TARBALL" /usr/local/bin >/dev/null

    echo "  cilium CLI v${CLI_VERSION} installed" >&2
fi

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
