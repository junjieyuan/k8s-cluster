#!/usr/bin/env bash
set -euo pipefail

# Auto-escalate to root (kubeadm requires privileges)
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOIN_TEMPLATE="${SCRIPT_DIR}/kubeadm-join-worker.yaml"

usage() {
    cat <<'EOF'
Usage: join-worker.sh --token TOKEN --hash HASH [OPTIONS]

Join a worker node to an existing Kubernetes cluster.

Required:
  --token TOKEN     Bootstrap token (from kubeadm token create --print-join-command)
  --hash HASH       CA cert hash, e.g. sha256:abc123...
  --endpoint HOST   API server endpoint, e.g. control-plane.example.com:6443

Options:
  --config PATH     kubeadm join config template (default: bootstrap/kubeadm/kubeadm-join-worker.yaml)
  --dry-run         Print the join command without executing
  --help            Show this help
EOF
    exit "${1:-0}"
}

TOKEN=""
HASH=""
ENDPOINT=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)    TOKEN="$2";    shift 2 ;;
        --hash)     HASH="$2";     shift 2 ;;
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --config)   JOIN_TEMPLATE="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true;  shift ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# Validate required args
[[ -z "$TOKEN" ]]    && { echo "Error: --token is required" >&2; usage 1; }
[[ -z "$HASH" ]]     && { echo "Error: --hash is required" >&2;  usage 1; }
[[ -z "$ENDPOINT" ]] && { echo "Error: --endpoint is required" >&2; usage 1; }
[[ -f "$JOIN_TEMPLATE" ]] || { echo "Error: Join template not found at $JOIN_TEMPLATE" >&2; exit 1; }

for bin in kubeadm envsubst; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found" >&2; exit 1; }
done

# Generate join config from template, substituting token/hash/endpoint
JOIN_CONFIG="$(mktemp /tmp/kubeadm-join.XXXXXX.yaml)"
trap 'rm -f "$JOIN_CONFIG"' EXIT

TOKEN="$TOKEN" HASH="$HASH" ENDPOINT="$ENDPOINT" envsubst '$TOKEN $HASH $ENDPOINT' < "$JOIN_TEMPLATE" > "$JOIN_CONFIG"

if $DRY_RUN; then
    echo "DRY-RUN:" >&2
    echo "  kubeadm join --config=$JOIN_CONFIG" >&2
    echo "Generated config:" >&2
    cat "$JOIN_CONFIG" >&2
    exit 0
fi

# Open firewall ports if firewalld is active (ublue GPU workers have it; FCOS does not)
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "Configuring firewalld for worker node..." >&2
    firewall-cmd --permanent --add-service=kube-worker    # kubelet + NodePort TCP
    firewall-cmd --permanent --add-port=30000-32767/udp   # NodePort UDP (not in kube-worker)
    firewall-cmd --permanent --add-port=6081/udp          # Cilium Geneve overlay
    firewall-cmd --permanent --add-port=8472/udp          # Cilium VXLAN overlay (fallback)
    firewall-cmd --permanent --add-port=4240/tcp           # Cilium health checks
    firewall-cmd --reload
    echo "  [OK] firewalld worker ports configured" >&2
fi

echo "Joining Kubernetes cluster at $ENDPOINT..." >&2
kubeadm join --config="$JOIN_CONFIG"

echo "Node joined successfully." >&2
