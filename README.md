# k8s-cluster

Provision a Kubernetes cluster on Fedora CoreOS VMs using libvirt + Butane/Ignition + kubeadm + Cilium.

## Overview

- **Runtime**: CRI-O
- **CNI**: Cilium (cluster-pool IPAM, default `172.16.0.0/12`)
- **OS**: Fedora CoreOS (immutable, updated via rpm-ostree at first boot)
- **Hypervisor**: libvirt/KVM with QCOW2 backing images

### Files

```
├── core-install.sh          # Provision FCOS VMs via virt-install
├── upload-image.sh          # Upload disk image to libvirt storage pool
├── butane/
│   ├── build.sh             # Compile Butane template → Ignition config
│   ├── node.bu.tmpl         # Butane template (user, hostname, kernel, packages)
│   └── .env.example         # Configuration template
└── init/
    ├── init-node.sh         # Kernel modules, sysctl, enable CRI-O/kubelet
    ├── init-control-plane.sh # kubeadm init + optional Cilium install
    ├── join-cluster.sh      # kubeadm join for worker nodes
    ├── cilium.sh            # Install Cilium CNI
    ├── kubeadm-init.yaml    # kubeadm InitConfiguration + ClusterConfiguration
    └── kubeadm-join.yaml    # kubeadm JoinConfiguration template
```

### Network CIDRs

| Type | CIDR | Capacity |
|------|------|----------|
| Pod | `172.16.0.0/12` | ~1M IPs |
| Service | `10.96.0.0/12` | ~1M IPs (k8s default) |

## Prerequisites

- Linux host with KVM/libvirt (`virt-install`, `virsh`)
- [Butane](https://coreos.github.io/butane/) (`butane`)
- `envsubst` (usually in `gettext` package)
- FCOS QCOW2 image uploaded to libvirt storage pool (see step 1)
- `kubeadm`, `kubectl` (for init/join scripts)
- [Cilium CLI](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/) (for CNI install)

## Usage

### 1. Download and Upload FCOS Image

```bash
# Download latest stable FCOS QCOW2
curl -LO https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/latest/x86_64/fedora-coreos-qemu.x86_64.qcow2

# Upload to libvirt default storage pool (SHA512-verified)
bash upload-image.sh fedora-coreos-*.qcow2
```

### 2. Configure Credentials

```bash
cp butane/.env.example butane/.env
# Edit .env:
#   PASSWORD_HASH=<run: openssl passwd -6>
#   SSH_PUB_KEY=<your public key>
#   HOSTNAME=k8s-control-plane-001
```

### 3. Build Ignition Config

```bash
bash butane/build.sh          # generates butane/node.ign
bash butane/build.sh --validate  # validate only, no output
```

### 4. Provision Control Plane VM

```bash
bash core-install.sh                          # defaults
bash core-install.sh --cpus 4 --memory 8192   # recommended for control plane
bash core-install.sh --dry-run                # preview without executing
```

The VM boots, applies Ignition config, installs CRI-O and Kubernetes via rpm-ostree, and reboots. Wait ~2-3 minutes for the reboot to complete.

### 5. Initialize the Node

```bash
# SSH into the VM (use virsh net-dhcp-leases virbr0 to find IP)
ssh core@<vm-ip>

# Run init scripts (clone the repo or copy them over)
bash init/init-node.sh
sudo bash init/init-control-plane.sh --configure-kubectl --install-cni
```

### 6. Add Worker Nodes (Optional)

```bash
# On the control plane, get the join info:
sudo kubeadm token create --print-join-command
# Output: kubeadm join control-plane.k8s.junjie.pro:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx

# Edit .env, set HOSTNAME=k8s-worker-001, rebuild Ignition
bash butane/build.sh

# Provision worker VM
bash core-install.sh --name k8s-worker-001 --cpus 2 --memory 4096 --no-blockpull

# SSH into worker, init node, join cluster
ssh core@<worker-ip>
bash init/init-node.sh
bash init/join-cluster.sh \
    --token <token> \
    --hash sha256:<hash> \
    --endpoint control-plane.k8s.junjie.pro:6443
```

## Reference

### `core-install.sh` Options

| Option | Default | Description |
|--------|---------|-------------|
| `--name` | `k8s-control-plane-001` | Libvirt domain name |
| `--cpus` | `2` | vCPUs |
| `--memory` | `4096` | Memory in MiB |
| `--disk-size` | `64` | Disk in GiB |
| `--image` | auto-detect | FCOS QCOW2 path |
| `--network` | `virbr0` | Bridge name |
| `--os-variant` | `fedora-coreos-stable` | osinfo variant |
| `--ignition` | `butane/node.ign` | Ignition file path |
| `--no-blockpull` | off | Skip backing file pull |
| `--dry-run` | off | Print command only |

### `upload-image.sh` Options

| Option | Default | Description |
|--------|---------|-------------|
| `--pool` | `default` | Storage pool name |
| `--name` | image basename | Volume name in pool |
| `--format` | `raw` | Volume format |

### `butane/build.sh` Options

| Option | Description |
|--------|-------------|
| `--validate` | Validate template, no output |

### `.env` Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PASSWORD_HASH` | yes | — | `openssl passwd -6` output |
| `SSH_PUB_KEY` | yes | — | SSH public key for core user |
| `HOSTNAME` | no | `k8s-control-plane-001` | OS hostname |
| `CRIO_VERSION` | no | `cri-o1.35` | CRI-O rpm-ostree package |
| `KUBERNETES_VERSION` | no | `kubernetes1.35` | Kubernetes rpm-ostree package |
