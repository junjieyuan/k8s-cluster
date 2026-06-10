#!/usr/bin/env bash
set -euo pipefail

# Auto-escalate to root (virsh, virt-install, and image paths require privileges)
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: vm-deploy.sh [OPTIONS]

Provision a Fedora CoreOS VM backed by a QCOW2 image, injecting an Ignition config.

Either --type or --ignition is required:
  --type TYPE       Node type (k8s-node or storage-server). Runs the corresponding
                    build.sh to generate the Ignition config before deploying.
  --ignition PATH   Path to .ign file (skip build, deploy only).

Options:
  --name NAME       VM name (default: k8s-control-plane-001)
  --cpus N          Number of vCPUs (default: 2)
  --memory MiB      Memory in MiB (default: 4096)
  --disk-size GiB   Disk size in GiB (default: 64)
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
VM_NAME="k8s-control-plane-001"
VM_CPUS="2"
VM_MEMORY="4096"
VM_IMAGE=""
VM_OS="fedora-coreos-stable"
VM_DISK_SIZE="64"
VM_NETWORK="virbr0"
IGNITION_FILE=""
DRY_RUN=false
BLOCKPULL=true

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
        --ignition)   IGNITION_FILE="$2"; shift 2 ;;
        --no-blockpull) BLOCKPULL=false;  shift ;;
        --dry-run)    DRY_RUN=true;       shift ;;
        --help)       usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# --- Pre-flight helper ---
fail() { echo "Error: $*" >&2; exit 1; }

# --- Resolve ignition source ---
if [[ -n "$NODE_TYPE" && -n "$IGNITION_FILE" ]]; then
    fail "--type and --ignition are mutually exclusive"
fi

if [[ -n "$NODE_TYPE" ]]; then
    case "$NODE_TYPE" in
        k8s-node)
            BUILD_DIR="${SCRIPT_DIR}/k8s-node"
            IGNITION_FILE="${BUILD_DIR}/node.ign"
            ;;
        storage-server)
            BUILD_DIR="${SCRIPT_DIR}/storage-server"
            IGNITION_FILE="${BUILD_DIR}/storage.ign"
            ;;
        *)
            fail "Unknown type: $NODE_TYPE (expected k8s-node or storage-server)"
            ;;
    esac

    BUILD_SCRIPT="${BUILD_DIR}/build.sh"
    [[ -f "$BUILD_SCRIPT" ]] || fail "Build script not found: $BUILD_SCRIPT"

    if $DRY_RUN; then
        echo "DRY-RUN: would run $BUILD_SCRIPT" >&2
    else
        echo "Building Ignition config for $NODE_TYPE..." >&2
        bash "$BUILD_SCRIPT"
    fi
fi

if [[ -z "$IGNITION_FILE" ]]; then
    fail "Either --type or --ignition is required"
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
[[ -f "$VM_IMAGE" ]]      || fail "FCOS image not found at $VM_IMAGE"
[[ -f "$IGNITION_FILE" ]] || fail "Ignition file not found at $IGNITION_FILE"
command -v virt-install >/dev/null 2>&1 || fail "virt-install not found (install virt-install package)"
command -v virsh >/dev/null 2>&1       || fail "virsh not found (install libvirt-client)"

if virsh dominfo "$VM_NAME" &>/dev/null; then
    fail "VM '$VM_NAME' already exists. Remove it with: virsh destroy $VM_NAME && virsh undefine $VM_NAME"
fi

# --- Dry-run ---
if $DRY_RUN; then
    echo "DRY-RUN: would execute:" >&2
    cat <<EOF >&2
virt-install \\
    --connect=qemu:///system \\
    --name=$VM_NAME \\
    --vcpus=$VM_CPUS \\
    --memory=$VM_MEMORY \\
    --os-variant=$VM_OS \\
    --import \\
    --disk=size=$VM_DISK_SIZE,backing_store=$VM_IMAGE \\
    --graphics=none \\
    --network bridge=$VM_NETWORK \\
    --sysinfo type=fwcfg,entry0.name=opt/com.coreos/config,entry0.file=$IGNITION_FILE \\
    --noautoconsole
EOF
    $BLOCKPULL && echo "virsh blockpull $VM_NAME vda --wait --verbose" >&2
    echo "virsh autostart $VM_NAME" >&2
    echo "virsh dumpxml $VM_NAME | sed '/<sysinfo/,/<\\/sysinfo>/d' | virsh define /dev/stdin" >&2
    exit 0
fi

# --- Provision VM ---
echo "Provisioning VM '$VM_NAME'..." >&2

cleanup() {
    echo "Cleaning up failed VM '$VM_NAME'..." >&2
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" 2>/dev/null || true
}
trap cleanup ERR

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
    --noautoconsole

trap - ERR

echo "VM '$VM_NAME' provisioned successfully." >&2

echo "Enabling autostart..." >&2
virsh autostart "$VM_NAME"

echo "Removing Ignition config (fwcfg) from VM definition..." >&2
virsh dumpxml "$VM_NAME" | sed '/<sysinfo/,/<\/sysinfo>/d' | virsh define /dev/stdin

if $BLOCKPULL; then
    echo "Pulling backing image into overlay (blockpull)..." >&2
    virsh blockpull "$VM_NAME" vda --wait --verbose
    echo "Blockpull complete." >&2
fi
