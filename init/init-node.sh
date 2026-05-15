#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: init-node.sh [OPTIONS]

Initialize a Kubernetes node: load kernel modules, apply sysctl, enable CRI-O and kubelet.
Run on every node before kubeadm init or join.

Options:
  --help   Show this help
EOF
    exit "${1:-0}"
}

[[ "${1:-}" == "--help" ]] && usage 0
[[ $# -gt 0 ]] && { echo "Unknown option: $1" >&2; usage 1; }

# Use sudo if not root
SUDO=""
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
fi

echo "Loading kernel modules..." >&2
$SUDO modprobe overlay
$SUDO modprobe br_netfilter

echo "Applying sysctl parameters..." >&2
$SUDO sysctl --system >/dev/null

echo "Verifying kernel modules..." >&2
lsmod | grep -q br_netfilter && echo "  [OK] br_netfilter" >&2 || { echo "  [FAIL] br_netfilter" >&2; exit 1; }
lsmod | grep -q overlay      && echo "  [OK] overlay"      >&2 || { echo "  [FAIL] overlay" >&2; exit 1; }

echo "Verifying sysctl params..." >&2
$SUDO sysctl net.bridge.bridge-nf-call-iptables \
             net.bridge.bridge-nf-call-ip6tables \
             net.ipv4.ip_forward \
             net.ipv6.conf.all.forwarding \
             net.ipv6.conf.default.forwarding >&2

echo "Checking CRI-O and kubelet are installed..." >&2
for bin in crio kubelet; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "  [FAIL] $bin not found — rpm-ostree install may have failed" >&2
        exit 1
    fi
    echo "  [OK] $bin" >&2
done

echo "Enabling CRI-O and kubelet..." >&2
$SUDO systemctl enable --now crio
$SUDO systemctl enable --now kubelet

echo "Node initialization complete." >&2
