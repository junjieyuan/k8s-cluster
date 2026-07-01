#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="external-dns"
EXTERNAL_DNS_VERSION="${EXTERNAL_DNS_VERSION:-v0.21.0}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy external-dns to sync Gateway API hostnames to Cloudflare DNS.
Requires a Cloudflare API token with Zone:DNS:Edit permission.

Options:
  --cf-token TOKEN       Cloudflare API token (required unless secret already exists)
  --domain-filter DOMAIN  DNS zone to manage (default: junjie.pro)
  --version VERSION       external-dns image tag (default: v0.21.0)
  --dry-run              Print resources without applying
  --help                 Show this help
EOF
    exit "${1:-0}"
}

CF_TOKEN=""
DOMAIN_FILTER="junjie.pro"
VERSION="${EXTERNAL_DNS_VERSION}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cf-token)       CF_TOKEN="$2";         shift 2 ;;
        --domain-filter)  DOMAIN_FILTER="$2";    shift 2 ;;
        --version)        VERSION="$2";          shift 2 ;;
        --dry-run)        DRY_RUN=true;           shift ;;
        --help)           usage 0 ;;
        *)                echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

if $DRY_RUN; then
    echo "DRY-RUN: kubectl apply -f ${SCRIPT_DIR}/namespace.yaml"
    echo "DRY-RUN: kubectl apply -f ${SCRIPT_DIR}/serviceaccount.yaml"
    echo "DRY-RUN: kubectl apply -f ${SCRIPT_DIR}/clusterrole.yaml"
    echo "DRY-RUN: kubectl apply -f ${SCRIPT_DIR}/clusterrolebinding.yaml"
    echo "DRY-RUN: create secret cloudflare-api-token"
    echo "DRY-RUN: envsubst + kubectl apply deployment.yaml (version=${VERSION}, domain-filter=${DOMAIN_FILTER})"
    exit 0
fi

echo "Deploying external-dns ${VERSION}..."

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
    echo "  kubectl create secret generic ${SECRET_NAME} --from-literal=api-token=<token> -n ${NAMESPACE}" >&2
    exit 1
fi

echo "-> Deploying external-dns..."
DEPLOYMENT_YAML="$(mktemp)"
trap "rm -f \"$DEPLOYMENT_YAML\"" EXIT
export DOMAIN_FILTER VERSION
envsubst '$DOMAIN_FILTER $VERSION' < "${SCRIPT_DIR}/deployment.yaml" > "$DEPLOYMENT_YAML"
kubectl apply -f "$DEPLOYMENT_YAML"
rm -f "$DEPLOYMENT_YAML"

echo "-> Waiting for deployment to be ready..."
kubectl rollout status deployment/external-dns -n "${NAMESPACE}" --timeout=120s

echo ""
echo "external-dns deployed."
echo "  Namespace: ${NAMESPACE}"
echo "  Version:   ${VERSION}"
echo "  Domain:    *.${DOMAIN_FILTER}"
echo "  Source:    Gateway HTTPRoute / GRPCRoute"
