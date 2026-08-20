#!/usr/bin/env bash
# Compile a Butane template (.bu.tmpl) into an Ignition config (.ign).
# Shared by all bootstrap types; replaces the per-type build.sh.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-ignition.sh --template PATH [OPTIONS]

Compile a Butane template into an Ignition config, substituting variables
from a .env file.

Options:
  --template PATH   Butane template file (required)
  --env PATH        .env file (default: same directory as template)
  --validate        Validate the template without generating output
  --help            Show this help
EOF
    exit "${1:-0}"
}

TEMPLATE=""
ENV_FILE=""
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template) TEMPLATE="$2";       shift 2 ;;
        --env)      ENV_FILE="$2";        shift 2 ;;
        --validate) VALIDATE_ONLY=true;   shift ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$TEMPLATE" ]] || { echo "Error: --template is required" >&2; usage 1; }
[[ -f "$TEMPLATE" ]] || { echo "Error: template not found: $TEMPLATE" >&2; exit 1; }

# Default .env to template's directory
if [[ -z "$ENV_FILE" ]]; then
    ENV_FILE="$(dirname "$TEMPLATE")/.env"
fi

# Check dependencies
for bin in butane envsubst; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found" >&2; exit 1; }
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in the values." >&2
    exit 1
fi

# Load variables
set -a; source "$ENV_FILE"; set +a

# Render the ssh_authorized_keys list from K8S_SSH_PUB_KEYS (multi-line, one
# key per line). envsubst cannot expand one variable into multiple YAML list
# items, so build the pre-indented block here and substitute it whole.
K8S_SSH_KEYS_BLOCK=""
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim (also catches stray \r)
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -n "$line" ]] && K8S_SSH_KEYS_BLOCK+="        - $line"$'\n'
done <<< "${K8S_SSH_PUB_KEYS:-}"
K8S_SSH_KEYS_BLOCK="${K8S_SSH_KEYS_BLOCK%$'\n'}"
if [[ -z "$K8S_SSH_KEYS_BLOCK" ]]; then
    echo "Error: No SSH public keys configured. Set K8S_SSH_PUB_KEYS in .env (one key per line)." >&2
    exit 1
fi
export K8S_SSH_KEYS_BLOCK

# Auto-extract all ${VAR} references from the template and build envsubst arg.
# This avoids hard-coding variable names per type (e.g. K8S_NFS_SUBNET is
# specific to storage-server).
ENVSUBST_VARS=$(grep -o '\${[A-Z_][A-Z_0-9]*}' "$TEMPLATE" | sort -u | sed 's/^\${/\$/; s/}$//' | paste -sd ' ' -)

# Validate required vars (universal across all types)
REQUIRED_VARS=("K8S_PASSWORD_HASH" "K8S_HOSTNAME" "K8S_PREINSTALLED_PACKAGES")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable $var is not set in .env" >&2
        exit 1
    fi
done

# Output: node.bu.tmpl -> node.ign, gpu-worker.bu.tmpl -> gpu-worker.ign, etc.
OUTPUT="${TEMPLATE%.bu.tmpl}.ign"

if $VALIDATE_ONLY; then
    echo "Validating $TEMPLATE..." >&2
    envsubst "$ENVSUBST_VARS" < "$TEMPLATE" | butane --check
    echo "Template is valid." >&2
    exit 0
fi

# Remove stale output owned by qemu from a previous provisioning run
rm -f "$OUTPUT"
echo "Compiling $TEMPLATE -> $OUTPUT..." >&2
envsubst "$ENVSUBST_VARS" < "$TEMPLATE" | butane -o "$OUTPUT"
echo "Generated $OUTPUT" >&2
