#!/usr/bin/env bash
set -euo pipefail

# Auto-escalate to root (kubeadm requires privileges)
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBEADM_CONFIG="${SCRIPT_DIR}/kubeadm-init.yaml"
CILIUM_SCRIPT="${SCRIPT_DIR}/../infrastructure/network-cilium/install.sh"

usage() {
    cat <<'EOF'
Usage: init-control-plane.sh [OPTIONS]

Bootstrap a Kubernetes control plane with kubeadm and optionally install Cilium CNI.

Options:
  --endpoint HOST:PORT  API server endpoint (default: control-plane.k8s.junjie.pro:6443)
  --config PATH         kubeadm init config template (default: bootstrap/kubeadm/kubeadm-init.yaml)
  --configure-kubectl   Copy admin.conf to ~/.kube/config after init
  --install-cni         Run infrastructure/network-cilium/install.sh after init
  --cni-version VER    Cilium version (default: 1.19.4)
  --pod-cidr CIDR       Pod IPv4 CIDR (default: 172.16.0.0/12)
  --dry-run             Print commands without executing
  --help                Show this help
EOF
    exit "${1:-0}"
}

CONFIGURE_KUBECTL=false
INSTALL_CNI=false
CNI_VERSION="1.19.4"
POD_CIDR="172.16.0.0/12"
CONTROL_PLANE_ENDPOINT="control-plane.k8s.junjie.pro:6443"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)            KUBEADM_CONFIG="$2"; shift 2 ;;
        --endpoint)          CONTROL_PLANE_ENDPOINT="$2"; shift 2 ;;
        --configure-kubectl) CONFIGURE_KUBECTL=true;  shift ;;
        --install-cni)       INSTALL_CNI=true;         shift ;;
        --cni-version)       CNI_VERSION="$2";          shift 2 ;;
        --pod-cidr)          POD_CIDR="$2";             shift 2 ;;
        --dry-run)           DRY_RUN=true;              shift ;;
        --help)              usage 0 ;;
        *)                   echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

command -v kubeadm >/dev/null 2>&1 || { echo "Error: kubeadm not found" >&2; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "Error: envsubst not found" >&2; exit 1; }

# Generate kubeadm config from template, substituting endpoint
KUBEADM_GENERATED="$(mktemp /tmp/kubeadm-init.XXXXXX.yaml)"
trap 'rm -f "$KUBEADM_GENERATED"' EXIT
CONTROL_PLANE_ENDPOINT="$CONTROL_PLANE_ENDPOINT" envsubst '$CONTROL_PLANE_ENDPOINT' < "$KUBEADM_CONFIG" > "$KUBEADM_GENERATED"

if $DRY_RUN; then
    echo "DRY-RUN:" >&2
    echo "  kubeadm init --config=$KUBEADM_GENERATED" >&2
    echo "Generated config:" >&2
    cat "$KUBEADM_GENERATED" >&2
    if $CONFIGURE_KUBECTL; then
        echo "  mkdir -p \$HOME/.kube"
        echo "  cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config"
        echo "  chown \$(id -u):\$(id -g) \$HOME/.kube/config"
    fi
    if $INSTALL_CNI; then
        echo "  $CILIUM_SCRIPT --version $CNI_VERSION --cidr $POD_CIDR"
    fi
    exit 0
fi

# Open firewall ports if firewalld is active (ublue nodes have it; FCOS does not)
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Configuring firewalld for control-plane node..." >&2
    firewall-cmd --permanent --add-service=kube-control-plane-secure  # apiserver, etcd, controller-manager, scheduler
    firewall-cmd --permanent --add-service=kube-worker                # kubelet + NodePort TCP
    firewall-cmd --permanent --add-port=30000-32767/udp               # NodePort UDP
    firewall-cmd --permanent --add-port=6081/udp                      # Cilium Geneve overlay
    firewall-cmd --permanent --add-port=8472/udp                      # Cilium VXLAN overlay (fallback)
    firewall-cmd --permanent --add-port=4240/tcp                       # Cilium health checks
    firewall-cmd --reload
    echo "  [OK] firewalld control-plane ports configured" >&2
fi

echo "Initializing Kubernetes control plane at $CONTROL_PLANE_ENDPOINT..." >&2
kubeadm init --config="$KUBEADM_GENERATED"

echo "" >&2
echo "Control plane initialized successfully." >&2

if $CONFIGURE_KUBECTL; then
    echo "Configuring kubectl..." >&2
    mkdir -p "$HOME/.kube"
    cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
    chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    echo "kubectl configured." >&2
else
    echo "To configure kubectl, run:" >&2
    echo "  mkdir -p \$HOME/.kube" >&2
    echo "  cp -i /etc/kubernetes/admin.conf \$HOME/.kube/config" >&2
    echo "  chown \$(id -u):\$(id -g) \$HOME/.kube/config" >&2
fi

if $INSTALL_CNI; then
    echo "Installing Cilium CNI..." >&2
    bash "$CILIUM_SCRIPT" --version "$CNI_VERSION" --cidr "$POD_CIDR"
else
    echo "" >&2
    echo "To install Cilium CNI, run:" >&2
    echo "  bash $CILIUM_SCRIPT" >&2
fi
