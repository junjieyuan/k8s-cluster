#!/usr/bin/env bash
set -euo pipefail

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
  --config PATH          kubeadm join config template (default: init/kubeadm-join-control-plane.yaml)
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

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# Generate join config from template
JOIN_CONFIG="$(mktemp /tmp/kubeadm-join-cp.XXXXXX.yaml)"
trap 'rm -f "$JOIN_CONFIG"' EXIT

TOKEN="$TOKEN" HASH="$HASH" ENDPOINT="$ENDPOINT" CERTIFICATE_KEY="$CERTIFICATE_KEY" \
    envsubst '$TOKEN $HASH $ENDPOINT $CERTIFICATE_KEY' < "$JOIN_TEMPLATE" > "$JOIN_CONFIG"

if $DRY_RUN; then
    echo "DRY-RUN:" >&2
    echo "  $SUDO kubeadm join --config=$JOIN_CONFIG" >&2
    echo "Generated config:" >&2
    cat "$JOIN_CONFIG" >&2
    exit 0
fi

echo "Joining Kubernetes control plane at $ENDPOINT..." >&2
$SUDO kubeadm join --config="$JOIN_CONFIG"

echo "Control plane node joined successfully." >&2
