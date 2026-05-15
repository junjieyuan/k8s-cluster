#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build.sh [OPTIONS]

Compile the Butane template (node.bu.tmpl) into an Ignition config (node.ign),
substituting variables from .env.

Options:
  --validate   Validate the template without generating output
  --help       Show this help
EOF
    exit "${1:-0}"
}

VALIDATE_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --validate) VALIDATE_ONLY=true; shift ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
TEMPLATE="${SCRIPT_DIR}/node.bu.tmpl"
OUTPUT="${SCRIPT_DIR}/node.ign"

# Check dependencies
for bin in butane envsubst; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found" >&2; exit 1; }
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in the values." >&2
    exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: Template not found at $TEMPLATE" >&2
    exit 1
fi

# Load variables
set -a; source "$ENV_FILE"; set +a

# Validate required vars
REQUIRED_VARS=("K8S_PASSWORD_HASH" "K8S_SSH_PUB_KEY" "K8S_HOSTNAME" "K8S_CRIO_VERSION" "K8S_KUBERNETES_VERSION")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable $var is not set in .env" >&2
        exit 1
    fi
done

# Build envsubst variable list (only the vars we loaded) — single space-separated argument
ENVSUBST_VARS='$K8S_PASSWORD_HASH $K8S_SSH_PUB_KEY $K8S_HOSTNAME $K8S_CRIO_VERSION $K8S_KUBERNETES_VERSION'

if $VALIDATE_ONLY; then
    echo "Validating $TEMPLATE..." >&2
    envsubst "$ENVSUBST_VARS" < "$TEMPLATE" | butane --check
    echo "Template is valid." >&2
    exit 0
fi

echo "Compiling $TEMPLATE -> $OUTPUT..." >&2
envsubst "$ENVSUBST_VARS" < "$TEMPLATE" | butane -o "$OUTPUT"
echo "Generated $OUTPUT" >&2
