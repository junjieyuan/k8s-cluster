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

# Load only the required variables (secure: no blanket export)
REQUIRED_VARS=("PASSWORD_HASH" "SSH_PUB_KEY")
OPTIONAL_VARS=("HOSTNAME" "CRIO_VERSION" "KUBERNETES_VERSION")

# Source .env safely: read each key=value line, only set whitelisted vars
while IFS='=' read -r key value; do
    key="${key%%[[:space:]]*}"            # strip trailing whitespace from key
    [[ -z "$key" || "$key" =~ ^# ]] && continue  # skip empty lines and comments
    value="${value%%#*}"                             # strip inline comments
    value="${value#"${value%%[![:space:]]*}"}"    # strip leading whitespace
    value="${value%"${value##*[![:space:]]}"}"    # strip trailing whitespace
    value="${value#[\"']}"; value="${value%[\"']}" # strip optional quotes
    for varname in "${REQUIRED_VARS[@]}" "${OPTIONAL_VARS[@]}"; do
        if [[ "$key" == "$varname" ]]; then
            printf -v "$varname" '%s' "$value"
            break
        fi
    done
done < "$ENV_FILE"

# Validate required vars
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable $var is not set in .env" >&2
        exit 1
    fi
done

# Set defaults for optional vars
: "${HOSTNAME:=k8s-control-plane-001}"
: "${CRIO_VERSION:=cri-o1.35}"
: "${KUBERNETES_VERSION:=kubernetes1.35}"

# Build envsubst variable list (only the vars we loaded)
ENVSUBST_VARS=("\$PASSWORD_HASH" "\$SSH_PUB_KEY" "\$HOSTNAME" "\$CRIO_VERSION" "\$KUBERNETES_VERSION")

if $VALIDATE_ONLY; then
    echo "Validating $TEMPLATE..." >&2
    envsubst "${ENVSUBST_VARS[@]}" < "$TEMPLATE" | butane --check
    echo "Template is valid." >&2
    exit 0
fi

echo "Compiling $TEMPLATE -> $OUTPUT..." >&2
envsubst "${ENVSUBST_VARS[@]}" < "$TEMPLATE" | butane -o "$OUTPUT"
echo "Generated $OUTPUT" >&2
