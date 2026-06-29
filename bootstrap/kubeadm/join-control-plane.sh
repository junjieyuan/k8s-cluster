#!/usr/bin/env bash
set -euo pipefail

# Auto-escalate to root (kubeadm requires privileges)
if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOIN_TEMPLATE="${SCRIPT_DIR}/kubeadm-join-control-plane.yaml"

usage() {
    cat <<'EOF'
Usage: join-control-plane.sh --token TOKEN --hash HASH --certificate-key KEY [OPTIONS]

Join a control plane node to an existing Kubernetes cluster.

Required:
  --token TOKEN          Bootstrap token
  --hash HASH            CA cert hash, e.g. sha256:abc123...
  --endpoint HOST        API server endpoint, e.g. control-plane.example.com:6443
  --certificate-key KEY  Certificate key (from kubeadm init phase upload-certs)

Options:
  --config PATH          kubeadm join config template (default: bootstrap/kubeadm/kubeadm-join-control-plane.yaml)
  --dry-run              Print the join command without executing
  --help                 Show this help
EOF
    exit "${1:-0}"
}

TOKEN=""
HASH=""
ENDPOINT=""
CERTIFICATE_KEY=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)           TOKEN="$2";            shift 2 ;;
        --hash)            HASH="$2";             shift 2 ;;
        --endpoint)        ENDPOINT="$2";         shift 2 ;;
        --certificate-key) CERTIFICATE_KEY="$2";  shift 2 ;;
        --config)          JOIN_TEMPLATE="$2";    shift 2 ;;
        --dry-run)         DRY_RUN=true;          shift ;;
        --help)            usage 0 ;;
        *)                 echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$TOKEN" ]]           && { echo "Error: --token is required" >&2; usage 1; }
[[ -z "$HASH" ]]            && { echo "Error: --hash is required" >&2; usage 1; }
[[ -z "$ENDPOINT" ]]        && { echo "Error: --endpoint is required" >&2; usage 1; }
[[ -z "$CERTIFICATE_KEY" ]] && { echo "Error: --certificate-key is required" >&2; usage 1; }
[[ -f "$JOIN_TEMPLATE" ]]   || { echo "Error: Join template not found at $JOIN_TEMPLATE" >&2; exit 1; }

for bin in kubeadm envsubst; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found" >&2; exit 1; }
done

# Generate join config from template
JOIN_CONFIG="$(mktemp /tmp/kubeadm-join-cp.XXXXXX.yaml)"
trap 'rm -f "$JOIN_CONFIG"' EXIT

TOKEN="$TOKEN" HASH="$HASH" ENDPOINT="$ENDPOINT" CERTIFICATE_KEY="$CERTIFICATE_KEY" \
    envsubst '$TOKEN $HASH $ENDPOINT $CERTIFICATE_KEY' < "$JOIN_TEMPLATE" > "$JOIN_CONFIG"

if $DRY_RUN; then
    echo "DRY-RUN:" >&2
    echo "  kubeadm join --config=$JOIN_CONFIG" >&2
    echo "Generated config:" >&2
    cat "$JOIN_CONFIG" >&2
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

echo "Joining Kubernetes control plane at $ENDPOINT..." >&2
kubeadm join --config="$JOIN_CONFIG"

echo "Control plane node joined successfully." >&2
