#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: vm-deploy.sh --type TYPE [OPTIONS]

Provision a Fedora CoreOS VM backed by a QCOW2 image, injecting an Ignition config.
The --type argument determines how the ignition is built and which extra VM
configuration is applied (e.g. GPU passthrough).

Supported types: k8s-node, k8s-gpu-node, storage-server

Options:
  --type TYPE       Node type (k8s-node, k8s-gpu-node, or storage-server). Required.
  --name NAME       VM name (example: k8s-control-plane-001). Required.
  --cpus N          Number of vCPUs (default from .env: K8S_CPUS).
  --memory MiB      Memory in MiB (default from .env: K8S_MEMORY).
  --disk-size GiB   Disk size in GiB (default from .env: K8S_DISK_SIZE).
  --image PATH      Path to FCOS QCOW2 backing image
  --network BRIDGE  Network bridge name (default: virbr0)
  --os-variant OS   osinfo variant (default: fedora-coreos-stable)
  --no-blockpull    Skip blockpull after install
  --dry-run         Print the virt-install command without executing
  --help            Show this help
EOF
    exit "${1:-0}"
}

# --- Defaults ---
NODE_TYPE=""
VM_NAME=""
VM_CPUS=""
VM_MEMORY=""
VM_IMAGE=""
VM_OS="fedora-coreos-stable"
VM_DISK_SIZE=""
VM_NETWORK="virbr0"
DRY_RUN=false
BLOCKPULL=true

# Preserve original args for re-exec under sudo (the loop below consumes $@)
ORIGINAL_ARGS=("$@")

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)       NODE_TYPE="$2";     shift 2 ;;
        --name)       VM_NAME="$2";       shift 2 ;;
        --cpus)       VM_CPUS="$2";       shift 2 ;;
        --memory)     VM_MEMORY="$2";     shift 2 ;;
        --disk-size)  VM_DISK_SIZE="$2";  shift 2 ;;
        --image)      VM_IMAGE="$2";      shift 2 ;;
        --network)    VM_NETWORK="$2";    shift 2 ;;
        --os-variant) VM_OS="$2";         shift 2 ;;
        --no-blockpull) BLOCKPULL=false;  shift ;;
        --dry-run)    DRY_RUN=true;       shift ;;
        --help)       usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# --- Pre-flight helper ---
fail() { echo "Error: $*" >&2; exit 1; }

# --- Resolve type ---
if [[ -z "$NODE_TYPE" ]]; then
    fail "--type is required (one of: k8s-node, k8s-gpu-node, storage-server)"
fi

if [[ -z "$VM_NAME" ]]; then
    fail "--name is required (example: k8s-control-plane-001)"
fi

TYPE_DIR="${SCRIPT_DIR}/${NODE_TYPE}"
[[ -d "$TYPE_DIR" ]] || fail "Type directory not found: $TYPE_DIR"

DEPLOY_SCRIPT="${TYPE_DIR}/deploy.sh"
[[ -f "$DEPLOY_SCRIPT" ]] || fail "deploy.sh not found in $TYPE_DIR"

# Source type-specific deploy functions
# shellcheck disable=SC1090
source "$DEPLOY_SCRIPT"

# --- Hardware defaults from .env ---
if [[ -f "$TYPE_DIR/.env" ]]; then
    set -a; source "$TYPE_DIR/.env"; set +a
fi
VM_CPUS="${VM_CPUS:-${K8S_CPUS:-}}"
VM_MEMORY="${VM_MEMORY:-${K8S_MEMORY:-}}"
VM_DISK_SIZE="${VM_DISK_SIZE:-${K8S_DISK_SIZE:-}}"

if [[ -z "$VM_CPUS" ]]; then
    fail "--cpus is required (set K8S_CPUS in .env or pass --cpus)"
fi
if [[ -z "$VM_MEMORY" ]]; then
    fail "--memory is required (set K8S_MEMORY in .env or pass --memory)"
fi
if [[ -z "$VM_DISK_SIZE" ]]; then
    fail "--disk-size is required (set K8S_DISK_SIZE in .env or pass --disk-size)"
fi

# Check that required functions are defined
for fn in deploy_build deploy_extra_args deploy_finalize; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
        fail "deploy.sh must define function: $fn"
    fi
done

# --- Build ignition ---
echo "Building Ignition config for $NODE_TYPE..." >&2
deploy_build

IGNITION_FILE="${IGNITION_FILE:-}"
if [[ -z "$IGNITION_FILE" ]]; then
    fail "deploy_build did not set IGNITION_FILE"
fi

# --- Dry-run (exit before escalating to root) ---
if $DRY_RUN; then
    # Resolve default image for display (may not be accessible as user, but
    # the path is informational in dry-run mode).
    dry_image="${VM_IMAGE}"
    if [[ -z "$dry_image" ]]; then
        dry_image=$(ls -t /var/lib/libvirt/images/fedora-coreos-*.qcow2 2>/dev/null | head -1 || true)
        [[ -z "$dry_image" ]] && dry_image="/var/lib/libvirt/images/fedora-coreos-<latest>.qcow2"
    fi
    echo "DRY-RUN: would execute:" >&2
    cat <<DRYEOF >&2
virt-install \\
    --connect=qemu:///system \\
    --name=$VM_NAME \\
    --vcpus=$VM_CPUS \\
    --memory=$VM_MEMORY \\
    --os-variant=$VM_OS \\
    --import \\
    --disk=size=$VM_DISK_SIZE,backing_store=$dry_image \\
    --graphics=none \\
    --network bridge=$VM_NETWORK \\
    --sysinfo type=fwcfg,entry0.name=opt/com.coreos/config,entry0.file=$IGNITION_FILE \\
    --noautoconsole$(deploy_extra_args | sed 's/^/ \\\n    /')
DRYEOF
    $BLOCKPULL && echo "virsh blockpull $VM_NAME vda --wait --verbose" >&2
    echo "virsh autostart $VM_NAME" >&2
    echo "virsh dumpxml $VM_NAME | sed '/<sysinfo/,/<\/sysinfo>/d' | virsh define /dev/stdin" >&2
    echo "[deploy_finalize $VM_NAME]" >&2
    exit 0
fi

# --- Escalate to root for provisioning ---
if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "${ORIGINAL_ARGS[@]}"
fi

# --- Default image path if not specified ---
if [[ -z "$VM_IMAGE" ]]; then
    VM_IMAGE=$(ls -t /var/lib/libvirt/images/fedora-coreos-*.qcow2 2>/dev/null | head -1 || true)
    if [[ -z "$VM_IMAGE" ]]; then
        fail "No FCOS image found in /var/lib/libvirt/images/ and --image not specified."
    fi
    echo "Using image: $VM_IMAGE" >&2
fi

# --- Pre-flight checks ---
[[ -f "$VM_IMAGE"      ]] || fail "FCOS image not found at $VM_IMAGE"
[[ -f "$IGNITION_FILE" ]] || fail "Ignition file not found at $IGNITION_FILE"
command -v virt-install >/dev/null 2>&1 || fail "virt-install not found (install virt-install package)"
command -v virsh >/dev/null 2>&1       || fail "virsh not found (install libvirt-client)"

if virsh dominfo "$VM_NAME" &>/dev/null; then
    fail "VM '$VM_NAME' already exists. Remove it with: sudo virsh destroy $VM_NAME && sudo virsh undefine --domain $VM_NAME --managed-save --remove-all-storage --snapshots-metadata --checkpoints-metadata --nvram --tpm"
fi

# --- Provision VM ---
echo "Provisioning VM '$VM_NAME'..." >&2

cleanup() {
    echo "Cleaning up failed VM '$VM_NAME'..." >&2
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine --domain "$VM_NAME" --managed-save --remove-all-storage --snapshots-metadata --checkpoints-metadata --nvram --tpm 2>/dev/null || true
}
trap cleanup ERR

# Read extra args into an array safely
readarray -t EXTRA_ARGS < <(deploy_extra_args)

virt-install \
    --connect="qemu:///system" \
    --name="$VM_NAME" \
    --vcpus="$VM_CPUS" \
    --memory="$VM_MEMORY" \
    --os-variant="$VM_OS" \
    --import \
    --disk="size=$VM_DISK_SIZE,backing_store=$VM_IMAGE" \
    --graphics=none \
    --network bridge="$VM_NETWORK" \
    --sysinfo type=fwcfg,entry0.name=opt/com.coreos/config,entry0.file="$IGNITION_FILE" \
    --noautoconsole \
    "${EXTRA_ARGS[@]}"

trap - ERR

echo "VM '$VM_NAME' provisioned successfully." >&2

echo "Enabling autostart..." >&2
virsh autostart "$VM_NAME"

echo "Removing Ignition config (fwcfg) from VM definition..." >&2
virsh dumpxml "$VM_NAME" | sed '/<sysinfo/,/<\/sysinfo>/d' | virsh define /dev/stdin
rm -f "$IGNITION_FILE"
echo "Cleaned up Ignition file." >&2

if $BLOCKPULL; then
    echo "Pulling backing image into overlay (blockpull)..." >&2
    virsh blockpull "$VM_NAME" vda --wait --verbose
    echo "Blockpull complete." >&2
fi

# --- Type-specific finalization ---
deploy_finalize "$VM_NAME"
