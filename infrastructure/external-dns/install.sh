#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="external-dns"
EXTERNAL_DNS_VERSION="v0.21.0"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy external-dns to sync Gateway API hostnames to Cloudflare DNS.
Requires a Cloudflare API token with Zone:DNS:Edit permission.

Options:
  --cf-token TOKEN       Cloudflare API token (required unless secret already exists)
  --domain-filter DOMAIN  DNS zone to manage (default: junjie.pro)
  --dry-run              Print resources without applying
  --help                 Show this help
EOF
    exit "${1:-0}"
}

CF_TOKEN=""
DOMAIN_FILTER="junjie.pro"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cf-token)       CF_TOKEN="$2";         shift 2 ;;
        --domain-filter)  DOMAIN_FILTER="$2";    shift 2 ;;
        --dry-run)        DRY_RUN=true;           shift ;;
        --help)           usage 0 ;;
        *)                echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

echo "Deploying external-dns ${EXTERNAL_DNS_VERSION}..."

echo "-> Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "-> Creating RBAC..."
kubectl apply -f "${SCRIPT_DIR}/serviceaccount.yaml"
kubectl apply -f "${SCRIPT_DIR}/clusterrole.yaml"
kubectl apply -f "${SCRIPT_DIR}/clusterrolebinding.yaml"

SECRET_NAME="cloudflare-api-token"
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Using existing secret ${SECRET_NAME}."
elif [[ -n "$CF_TOKEN" ]]; then
    echo "-> Creating Cloudflare API token Secret..."
    kubectl create secret generic "${SECRET_NAME}" \
        --from-literal="api-token=${CF_TOKEN}" \
        -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    echo "  Secret ${SECRET_NAME} created."
else
    echo "Error: --cf-token is required (no existing secret ${SECRET_NAME})." >&2
    echo "  Or create secret manually from ${SCRIPT_DIR}/secret.yaml.example" >&2
    exit 1
fi

echo "-> Deploying external-dns..."
DEPLOYMENT_YAML="$(mktemp)"
trap "rm -f \"$DEPLOYMENT_YAML\"" EXIT
export DOMAIN_FILTER
envsubst '$DOMAIN_FILTER' < "${SCRIPT_DIR}/deployment.yaml" > "$DEPLOYMENT_YAML"
kubectl apply -f "$DEPLOYMENT_YAML"
rm -f "$DEPLOYMENT_YAML"

echo "-> Waiting for deployment to be ready..."
kubectl rollout status deployment/external-dns -n "${NAMESPACE}" --timeout=120s

echo ""
echo "external-dns deployed."
echo "  Namespace: ${NAMESPACE}"
echo "  Version:   ${EXTERNAL_DNS_VERSION}"
echo "  Domain:    *.${DOMAIN_FILTER}"
echo "  Source:    Gateway HTTPRoute / GRPCRoute"
