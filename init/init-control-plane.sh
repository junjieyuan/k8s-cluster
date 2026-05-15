#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBEADM_CONFIG="${SCRIPT_DIR}/kubeadm-init.yaml"
CILIUM_SCRIPT="${SCRIPT_DIR}/cilium.sh"

usage() {
    cat <<'EOF'
Usage: init-control-plane.sh [OPTIONS]

Bootstrap a Kubernetes control plane with kubeadm and optionally install Cilium CNI.

Options:
  --config PATH        kubeadm init config (default: init/kubeadm-init.yaml)
  --configure-kubectl  Copy admin.conf to ~/.kube/config after init
  --install-cni        Run cilium.sh after init
  --cni-version VER    Cilium version (default: 1.19.0)
  --pod-cidr CIDR      Pod IPv4 CIDR (default: 172.16.0.0/12)
  --dry-run            Print commands without executing
  --help               Show this help
EOF
    exit "${1:-0}"
}

CONFIGURE_KUBECTL=false
INSTALL_CNI=false
CNI_VERSION="1.19.0"
POD_CIDR="172.16.0.0/12"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)            KUBEADM_CONFIG="$2"; shift 2 ;;
        --configure-kubectl) CONFIGURE_KUBECTL=true;  shift ;;
        --install-cni)       INSTALL_CNI=true;         shift ;;
        --cni-version)       CNI_VERSION="$2";          shift 2 ;;
        --pod-cidr)          POD_CIDR="$2";             shift 2 ;;
        --dry-run)           DRY_RUN=true;              shift ;;
        --help)              usage 0 ;;
        *)                   echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ ! -f "$KUBEADM_CONFIG" ]]; then
    echo "Error: kubeadm config not found at $KUBEADM_CONFIG" >&2
    exit 1
fi

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

if $DRY_RUN; then
    echo "DRY-RUN:" >&2
    echo "  $SUDO kubeadm init --config=$KUBEADM_CONFIG"
    if $CONFIGURE_KUBECTL; then
        echo "  mkdir -p \$HOME/.kube"
        echo "  $SUDO cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
        echo "  $SUDO chown \$(id -u):\$(id -g) \$HOME/.kube/config"
    fi
    if $INSTALL_CNI; then
        echo "  $CILIUM_SCRIPT --version $CNI_VERSION --cidr $POD_CIDR"
    fi
    exit 0
fi

echo "Initializing Kubernetes control plane..." >&2
$SUDO kubeadm init --config="$KUBEADM_CONFIG"

echo "" >&2
echo "Control plane initialized successfully." >&2

if $CONFIGURE_KUBECTL; then
    echo "Configuring kubectl..." >&2
    mkdir -p "$HOME/.kube"
    $SUDO cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
    $SUDO chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    echo "kubectl configured." >&2
else
    echo "To configure kubectl, run:" >&2
    echo "  mkdir -p \$HOME/.kube" >&2
    echo "  $SUDO cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config" >&2
    echo "  $SUDO chown \$(id -u):\$(id -g) \$HOME/.kube/config" >&2
fi

if $INSTALL_CNI; then
    echo "Installing Cilium CNI..." >&2
    bash "$CILIUM_SCRIPT" --version "$CNI_VERSION" --cidr "$POD_CIDR"
else
    echo "" >&2
    echo "To install Cilium CNI, run:" >&2
    echo "  bash $CILIUM_SCRIPT" >&2
fi
