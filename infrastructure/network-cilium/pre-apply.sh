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

for bin in kubectl jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found" >&2; exit 1; }
done

kubectl cluster-info >/dev/null 2>&1 || {
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
}

# Gateway API CRDs BEFORE Cilium — the operator requires them at startup.
# Cilium 1.19 supports v1.5.1 CRDs with the deprecated v1alpha2 TLSRoute re-enabled:
# the operator probes CRD versions by presence (not the served flag) and would
# otherwise enable TLSRoute support against an unserved version.
GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml"
echo "Installing Gateway API CRDs..." >&2
if $DRY_RUN; then
    echo "DRY-RUN: kubectl apply -f $GATEWAY_API_URL"
else
    kubectl apply -f "$GATEWAY_API_URL"
fi

echo "Patching TLSRoute CRD for v1alpha2 compatibility..." >&2
if ! $DRY_RUN; then
    TLS_IDX=$(kubectl get crd tlsroutes.gateway.networking.k8s.io -o json | \
        jq -r '.spec.versions | to_entries[] | select(.value.name == "v1alpha2") | .key')
    if [[ -n "$TLS_IDX" ]]; then
        kubectl patch crd tlsroutes.gateway.networking.k8s.io --type=json \
            -p="[{\"op\": \"replace\", \"path\": \"/spec/versions/${TLS_IDX}/served\", \"value\": true}]"
    else
        echo "Warning: v1alpha2 not found in TLSRoute CRD versions — patch may no longer be needed." >&2
    fi
fi

echo "Done. Deploy with:" >&2
echo "  kubectl kustomize --enable-helm ${SCRIPT_DIR} | kubectl apply -f -" >&2
echo "  # fresh cluster: run the apply again after the operator registers Cilium CRDs" >&2
