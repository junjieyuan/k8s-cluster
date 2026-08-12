#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: pre-apply.sh [OPTIONS]

Bootstrap Gateway API CRDs before the Cilium kustomize apply.
- Gateway API CRDs come from the upstream release URL (not vendored); the
  version must match what the pinned Cilium version supports.
- Cilium's own CRDs are registered by cilium-operator at startup — no cilium CLI.

Then deploy:
  kubectl kustomize --enable-helm <repo>/infrastructure/network-cilium/ | kubectl apply -f -
On a fresh cluster, run the apply twice — the operator registers Cilium CRDs
between the runs (see docs/cilium-gateway.md).

Options:
  --dry-run           Print commands without executing
  --help              Show this help
EOF
    exit "${1:-0}"
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not found" >&2; exit 1; }

kubectl cluster-info >/dev/null 2>&1 || {
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
}

# Gateway API CRDs BEFORE Cilium — the operator requires them at startup.
# Cilium 1.20 requires Gateway API v1.6.1 (TLSRoute graduated to v1, served by
# the Standard channel). The Experimental channel additionally serves the
# deprecated v1alpha2/v1alpha3 — only needed for existing v1alpha2 TLSRoute
# objects, which this cluster does not use.
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"
echo "Installing Gateway API CRDs..." >&2
if $DRY_RUN; then
    echo "DRY-RUN: kubectl apply -f $GATEWAY_API_URL"
else
    kubectl apply -f "$GATEWAY_API_URL"
fi

echo "Done. Deploy with:" >&2
echo "  kubectl kustomize --enable-helm ${SCRIPT_DIR} | kubectl apply -f -" >&2
echo "  # fresh cluster: run the apply again after the operator registers Cilium CRDs" >&2
