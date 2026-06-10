#!/usr/bin/env bash
set -euo pipefail

# Auto-escalate to root (virsh requires privileges)
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

usage() {
    cat <<'EOF'
Usage: vm-image-upload.sh [OPTIONS] IMAGE_FILE

Upload a disk image to the libvirt default storage pool.
Validates the upload with SHA512 checksum comparison.

Options:
  --pool NAME     Storage pool name (default: default)
  --name NAME     Volume name (default: basename of IMAGE_FILE)
  --format FMT    Volume format (default: raw)
  --help          Show this help
EOF
    exit "${1:-0}"
}

POOL="default"
VOL_NAME=""
FORMAT="raw"
IMAGE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pool)   POOL="$2";    shift 2 ;;
        --name)   VOL_NAME="$2"; shift 2 ;;
        --format) FORMAT="$2";  shift 2 ;;
        --help)   usage 0 ;;
        -*)       echo "Unknown option: $1" >&2; usage 1 ;;
        *)        IMAGE_FILE="$1"; shift ;;
    esac
done

[[ -z "$IMAGE_FILE" ]] && { echo "Error: IMAGE_FILE is required" >&2; usage 1; }
[[ -f "$IMAGE_FILE" ]] || { echo "Error: file not found: $IMAGE_FILE" >&2; exit 1; }

command -v virsh >/dev/null 2>&1 || { echo "Error: virsh not found (install libvirt-client)" >&2; exit 1; }

# Default volume name to basename of image file
[[ -z "$VOL_NAME" ]] && VOL_NAME="$(basename "$IMAGE_FILE")"

# Get exact file size in bytes
SIZE=$(stat -c%s "$IMAGE_FILE")
[[ "$SIZE" -gt 0 ]] || { echo "Error: unable to determine file size or file is empty" >&2; exit 1; }

echo "Image:  $IMAGE_FILE" >&2
echo "Size:   $SIZE bytes ($(( SIZE / 1024 / 1024 )) MiB)" >&2
echo "Pool:   $POOL" >&2
echo "Volume: $VOL_NAME" >&2
echo "Format: $FORMAT" >&2
echo "" >&2

# Check pool exists
if ! virsh pool-info "$POOL" &>/dev/null; then
    echo "Error: storage pool '$POOL' not found" >&2
    exit 1
fi

# Check if volume already exists
if virsh vol-info --pool "$POOL" "$VOL_NAME" &>/dev/null; then
    echo "Error: volume '$VOL_NAME' already exists in pool '$POOL'" >&2
    exit 1
fi

echo "Creating volume..." >&2
virsh vol-create-as "$POOL" "$VOL_NAME" "$SIZE" --format "$FORMAT"

echo "Uploading..." >&2
virsh vol-upload --pool "$POOL" "$VOL_NAME" "$IMAGE_FILE"

echo "Verifying SHA512..." >&2
VOL_PATH=$(virsh vol-path --pool "$POOL" "$VOL_NAME")

SRC_HASH=$(sha512sum "$IMAGE_FILE" | awk '{print $1}')
DST_HASH=$(sha512sum "$VOL_PATH" | awk '{print $1}')

if [[ "$SRC_HASH" == "$DST_HASH" ]]; then
    echo "  [OK] SHA512 matches" >&2
else
    echo "  [FAIL] SHA512 mismatch!" >&2
    echo "  Source: $SRC_HASH" >&2
    echo "  Dest:   $DST_HASH" >&2
    exit 1
fi

echo "" >&2
echo "Upload complete: $VOL_PATH" >&2
