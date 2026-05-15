#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: core-install.sh [OPTIONS]

Provision a Fedora CoreOS VM backed by a QCOW2 image, injecting an Ignition config.

Options:
  --name NAME         VM name (default: k8s-control-plane-001)
  --cpus N            Number of vCPUs (default: 2)
  --memory MB         Memory in MiB (default: 4096)
  --disk-size GB      Disk size in GiB (default: 64)
  --image PATH        Path to FCOS QCOW2 backing image (required unless default exists)
  --network BRIDGE    Network bridge name (default: virbr0)
  --os-variant OS     osinfo variant (default: fedora-coreos-stable)
  --ignition FILE     Path to Ignition file (default: butane/node.ign)
  --no-blockpull      Skip blockpull after install (saves time/space)
  --dry-run           Print the virt-install command without executing
  --help              Show this help
EOF
    exit "${1:-0}"
}

# --- Defaults ---
VM_NAME="k8s-control-plane-001"
VM_CPUS="2"
VM_MEMORY="4096"
VM_IMAGE=""
VM_OS="fedora-coreos-stable"
VM_DISK_SIZE="64"
VM_NETWORK="virbr0"
DRY_RUN=false
BLOCKPULL=true
BUTANE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/butane" && pwd)"
IGNITION_FILE="${BUTANE_DIR}/node.ign"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
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

# --- Default image path if not specified ---
if [[ -z "$VM_IMAGE" ]]; then
    # Pick the most recent FCOS qcow2 in the standard libvirt images dir
    VM_IMAGE=$(ls -t /var/lib/libvirt/images/fedora-coreos-*.qcow2 2>/dev/null | head -1 || true)
    if [[ -z "$VM_IMAGE" ]]; then
        echo "Error: No FCOS image found in /var/lib/libvirt/images/ and --image not specified." >&2
        echo "Download one from https://fedoraproject.org/coreos/download" >&2
        exit 1
    fi
    echo "Using image: $VM_IMAGE" >&2
fi

# --- Pre-flight checks ---
fail() { echo "Error: $*" >&2; exit 1; }

[[ -f "$VM_IMAGE" ]]         || fail "FCOS image not found at $VM_IMAGE"
[[ -f "$IGNITION_FILE" ]]    || fail "Ignition file not found at $IGNITION_FILE (run butane/build.sh first)"
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

if $BLOCKPULL; then
    echo "Pulling backing image into overlay (blockpull)..." >&2
    virsh blockpull "$VM_NAME" vda --wait --verbose
    echo "Blockpull complete." >&2
fi
