#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="cert-manager"
CHART_REPO="https://charts.jetstack.io"
CHART_NAME="jetstack/cert-manager"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install cert-manager (via Helm) and configure Let's Encrypt ClusterIssuer
with Cloudflare DNS-01. A Cloudflare API token with Zone:DNS:Edit permission
is required.

Options:
  --email EMAIL         Email for Let's Encrypt notifications (required)
  --cf-token TOKEN      Cloudflare API token (required unless secret already exists)
  --staging             Use Let's Encrypt staging environment for testing (default: production)
  --dry-run             Print resources without applying
  --help                Show this help
EOF
    exit "${1:-0}"
}

ACME_EMAIL=""
CF_TOKEN=""
DRY_RUN=false
STAGING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)    ACME_EMAIL="$2";    shift 2 ;;
        --cf-token) CF_TOKEN="$2";      shift 2 ;;
        --staging)  STAGING=true;       shift ;;
        --dry-run)  DRY_RUN=true;       shift ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$ACME_EMAIL" ]]; then
    echo "Error: --email is required." >&2
    usage 1
fi

if ! command -v helm &>/dev/null; then
    echo "Error: helm is required. Install from https://helm.sh" >&2
    exit 1
fi

echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."

if ! helm repo list -o yaml 2>/dev/null | grep -q "https://charts.jetstack.io"; then
    echo "-> Adding jetstack Helm repo..."
    helm repo add jetstack "${CHART_REPO}"
fi
helm repo update jetstack

echo "-> Installing cert-manager via Helm (${CERT_MANAGER_VERSION})..."
helm upgrade --install cert-manager "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --values "${SCRIPT_DIR}/values.yaml" \
    --wait \
    --timeout 5m

echo "  cert-manager ready."

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

if [[ "$STAGING" == true ]]; then
    ISSUER_FILE="clusterissuer-staging.yaml"
else
    ISSUER_FILE="clusterissuer.yaml"
fi

if [[ ! -f "${SCRIPT_DIR}/${ISSUER_FILE}" ]]; then
    echo "Error: ${ISSUER_FILE} not found." >&2
    exit 1
fi

echo "-> Applying ClusterIssuer (${ISSUER_FILE})..."
export ACME_EMAIL
CLUSTERISSUER_YAML="$(mktemp)"
trap "rm -f \"$CLUSTERISSUER_YAML\"" EXIT
envsubst '$ACME_EMAIL' < "${SCRIPT_DIR}/${ISSUER_FILE}" > "$CLUSTERISSUER_YAML"
kubectl apply -f "$CLUSTERISSUER_YAML"
rm -f "$CLUSTERISSUER_YAML"

echo ""
echo "cert-manager ready."
echo "  Chart:      ${CHART_NAME} ${CERT_MANAGER_VERSION}"
echo "  ClusterIssuer: $(if [[ "$STAGING" == true ]]; then echo letsencrypt-staging; else echo letsencrypt-prod; fi)"
