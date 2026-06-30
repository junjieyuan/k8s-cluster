#!/usr/bin/env bash
set -euo pipefail

# Auto-escalate to root (modprobe, sysctl, systemctl require privileges)
if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

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

# Kubernetes requires swap off. ublue enables zram by default; FCOS does not.
if systemctl is-active --quiet systemd-zram-setup@zram0.service 2>/dev/null; then
    echo "Disabling zram swap..." >&2
    systemctl stop systemd-zram-setup@zram0.service
    systemctl mask systemd-zram-setup@zram0.service
fi

# Load kernel modules (systemd-modules-load should have done this after reboot;
# verify and only load if missing).
echo "Verifying kernel modules..." >&2
for mod in overlay br_netfilter; do
    if lsmod | grep -q "^${mod}\b"; then
        echo "  [OK] $mod" >&2
    else
        echo "  [MISS] $mod — loading now" >&2
        modprobe "$mod"
    fi
done

# Apply sysctl (systemd-sysctl should have done this; verify and apply if needed).
echo "Verifying sysctl params..." >&2
sysctl --system >/dev/null 2>&1

for param in net.bridge.bridge-nf-call-iptables \
             net.bridge.bridge-nf-call-ip6tables \
             net.ipv4.ip_forward \
             net.ipv6.conf.all.forwarding \
             net.ipv6.conf.default.forwarding; do
    val=$(sysctl -n "$param" 2>/dev/null || echo "unknown")
    if [[ "$val" == "1" ]]; then
        echo "  [OK] $param = $val" >&2
    else
        echo "  [FAIL] $param = $val (expected 1)" >&2
        exit 1
    fi
done

# Check binaries installed by rpm-ostree
echo "Checking CRI-O and kubelet are installed..." >&2
for bin in crio kubelet; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "  [FAIL] $bin not found — rpm-ostree install may have failed" >&2
        exit 1
    fi
    echo "  [OK] $bin" >&2
done

echo "Enabling CRI-O and kubelet..." >&2
# Enable before starting: ensures boot persistence even if a start fails and aborts the script.
systemctl enable crio kubelet
systemctl start crio
systemctl start kubelet

echo "Node initialization complete." >&2
