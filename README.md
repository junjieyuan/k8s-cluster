# k8s-cluster

Provision a Kubernetes cluster on Fedora CoreOS VMs using libvirt + Butane/Ignition + kubeadm + Cilium.

## Overview

- **Runtime**: CRI-O
- **CNI**: Cilium (cluster-pool IPAM, default `172.16.0.0/12`)
- **CSI**: NFS (csi-driver-nfs via Helm)
- **OS**: Fedora CoreOS (immutable, updated via rpm-ostree at first boot)
- **Hypervisor**: libvirt/KVM with QCOW2 backing images

### Files

```
.
├── AGENTS.md
├── bootstrap/
│   ├── vm-image-upload.sh                  # [host] Upload disk image to libvirt storage pool
│   ├── vm-deploy.sh                        # [host] Provision FCOS VMs via virt-install
│   ├── k8s-node/
│   │   ├── build.sh                        # [host] Compile Butane template -> Ignition config
│   │   ├── deploy.sh                       # [host] Type-specific deploy (sourced by vm-deploy.sh)
│   │   ├── node.bu.tmpl                    # [host] Butane template (user, hostname, kernel, packages)
│   │   └── .env.example                    # [host] Configuration template
│   ├── k8s-gpu-node/
│   │   ├── build.sh                        # [host] Compile Butane template -> Ignition config
│   │   ├── deploy.sh                       # [host] GPU-specific deploy (PCI passthrough, virtiofs)
│   │   ├── gpu-worker.bu.tmpl              # [host] Butane template (user, hostname, kernel)
│   │   └── .env.example                    # [host] Configuration template (GPU PCI, virtiofs)
│   ├── storage-server/
│   │   ├── build.sh                        # [host] Compile storage Butane template -> Ignition config
│   │   ├── deploy.sh                       # [host] Type-specific deploy (sourced by vm-deploy.sh)
│   │   ├── storage.bu.tmpl                 # [host] Butane template (NFS exports, packages)
│   │   └── .env.example                    # [host] Configuration template
│   └── kubeadm/
│       ├── init-node.sh                    # [vm]  Kernel modules, sysctl, disable zram swap, enable CRI-O/kubelet
│       ├── init-control-plane.sh           # [vm]  kubeadm init + firewalld + optional Cilium install
│       ├── join-worker.sh                  # [vm]  kubeadm join for worker nodes
│       ├── join-control-plane.sh           # [vm]  kubeadm join for control plane nodes
│       ├── kubeadm-init.yaml               # [vm]  kubeadm InitConfiguration + ClusterConfiguration
│       ├── kubeadm-join-worker.yaml        # [vm]  kubeadm JoinConfiguration template (worker)
│       └── kubeadm-join-control-plane.yaml # [vm]  kubeadm JoinConfiguration template (control plane)
└── infrastructure/
    ├── network-cilium/
    │   └── install.sh                      # [vm]  Install Cilium CNI
    ├── storage-nfs/
    │   ├── install.sh                      # [vm]  Deploy csi-driver-nfs via Helm
    │   └── storage-class.yaml              # [vm]  NFS StorageClass definition
    └── gpu-operator/
        ├── install.sh                      # [vm]  Deploy NVIDIA GPU Operator via Helm
        └── values.yaml                     # [vm]  Helm values (host driver reuse, CDI)
```

### Network CIDRs

| Type    | CIDR            | Capacity |
|---------|-----------------|----------|
| Pod     | `172.16.0.0/12` | ~1M IPs  |
| Service | `10.96.0.0/12`  | ~1M IPs  |

## Prerequisites

- Linux host with KVM/libvirt (`virt-install`, `virsh`)
- [Butane](https://coreos.github.io/butane/) (`butane`)
- `envsubst` (usually in `gettext` package)
- FCOS QCOW2 image uploaded to libvirt storage pool (see step 1)
- `kubeadm`, `kubectl` (for init/join scripts)
- [Helm](https://helm.sh/) (for infrastructure deployments)

## Usage

### On the Host

#### 1. Download and Upload FCOS Image

```bash
# Download latest stable FCOS QCOW2
curl -LO https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/latest/x86_64/fedora-coreos-qemu.x86_64.qcow2

# Upload to libvirt default storage pool (SHA512-verified)
bash bootstrap/vm-image-upload.sh fedora-coreos-*.qcow2
```

#### 2. Configure Credentials

```bash
# For k8s nodes
cp bootstrap/k8s-node/.env.example bootstrap/k8s-node/.env
# Edit .env:
#   K8S_PASSWORD_HASH=<run: openssl passwd -6>
#   K8S_SSH_PUB_KEY=<your public key>
#   Other vars (K8S_HOSTNAME, K8S_PREINSTALLED_PACKAGES) have defaults

# For GPU workers (optional)
cp bootstrap/k8s-gpu-node/.env.example bootstrap/k8s-gpu-node/.env
# Edit .env:
#   K8S_PASSWORD_HASH=<run: openssl passwd -6>
#   K8S_SSH_PUB_KEY=<your public key>
#   K8S_GPU_DEVICES="0000:01:00.0 0000:01:00.1"  # lspci -nn | grep -i nvidia
#   K8S_VIRTIOFS_SOURCE="/var/home/junjie/.cache/huggingface/hub"

# For storage server (optional)
cp bootstrap/storage-server/.env.example bootstrap/storage-server/.env
# Edit .env:
#   K8S_PASSWORD_HASH=<run: openssl passwd -6>
#   K8S_SSH_PUB_KEY=<your public key>
```

#### 3. Build Ignition Config

`vm-deploy.sh --type` auto-builds during deployment, but you can also build manually:

```bash
# K8s node
bash bootstrap/k8s-node/build.sh              # generates bootstrap/k8s-node/node.ign
bash bootstrap/k8s-node/build.sh --validate   # validate only, no output

# GPU worker
bash bootstrap/k8s-gpu-node/build.sh          # generates bootstrap/k8s-gpu-node/gpu-worker.ign

# Storage server
bash bootstrap/storage-server/build.sh        # generates bootstrap/storage-server/storage.ign
```

#### 4. Provision VMs

```bash
# Control plane
bash bootstrap/vm-deploy.sh --type k8s-node
bash bootstrap/vm-deploy.sh --type k8s-node --cpus 4 --memory 8192

# GPU worker (16 vCPUs / 32 GiB, with PCI passthrough + virtiofs)
bash bootstrap/vm-deploy.sh --type k8s-gpu-node --name k8s-gpu-worker-001 --cpus 16 --memory 32768

# Storage server
bash bootstrap/vm-deploy.sh --type storage-server --name k8s-storage-001

# Dry-run
bash bootstrap/vm-deploy.sh --type k8s-node --dry-run
```

The VM boots, applies Ignition config (including rpm-ostree install of cri-o + kubernetes), and reboots. Wait ~2-3 minutes for the reboot to complete.

For k8s-gpu-node type, the Ignition config follows [ublue's autorebase pattern](https://github.com/ublue-os/ucore#auto-rebase-install). Three reboots happen automatically:

1. **Unsigned rebase**: FCOS → `ucore-minimal:stable-nvidia` (unsigned) → reboot
2. **Signed rebase**: switch to signed image for verified updates → reboot
3. **Install k8s**: layer cri-o + kubernetes on uCore → reboot

No manual steps needed — after all reboots (~6-7 min), the VM is running signed uCore NVIDIA with k8s installed. The deploy script then stops the VM, attaches GPU PCI devices, virtiofs, sets CPU to host-passthrough and memory backing, then restarts.

### Inside the VM

Copy the `bootstrap/kubeadm/` directory to the VM, then SSH in.

```bash
# Find the VM IP
sudo virsh net-dhcp-leases default

# Copy kubeadm scripts to the VM
scp -r bootstrap/kubeadm core@<vm-ip>:~/

# SSH in
ssh core@<vm-ip>
```

#### 5. Initialize Control Plane

**Inside the VM**, after the first reboot completes (~2-3 min):

```bash
bash kubeadm/init-node.sh
bash kubeadm/init-control-plane.sh --configure-kubectl --install-cni
# Or with a custom endpoint:
# bash kubeadm/init-control-plane.sh --endpoint 192.168.122.100:6443 --configure-kubectl --install-cni
```

> **Note**: Use the VM's IP as the endpoint, and update DNS/hosts:
> ```bash
> echo '<control-plane-ip> control-plane.k8s.junjie.pro' | sudo tee -a /etc/hosts
> ```

#### 6. Add Worker Nodes

**On the Host** — get join token, then provision the worker:

```bash
# Get join info from control plane
ssh core@<control-plane-ip> sudo kubeadm token create --print-join-command
# Output: "kubeadm join <endpoint> --token xxx --discovery-token-ca-cert-hash sha256:xxx"

# Edit .env, set hostname, rebuild Ignition
sed -i 's/^K8S_HOSTNAME=.*/K8S_HOSTNAME=k8s-worker-001/' bootstrap/k8s-node/.env

# Provision worker VM
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-worker-001 --cpus 2 --memory 4096
```

**Inside the VM**, after reboot completes:

```bash
bash kubeadm/init-node.sh
bash kubeadm/join-worker.sh \
    --token <token> \
    --hash sha256:<hash> \
    --endpoint <control-plane-ip>:6443
```

> **GPU workers**: Same join procedure. `init-node.sh` handles ublue specifics (zram swap off, firewalld ports via `join-worker.sh`). The base image must be ucore before joining — rebase at first boot (see step 4).

#### 7. Add Control Plane Nodes (Optional)

**On the Host** — provision the new control plane VM:

```bash
sed -i 's/^K8S_HOSTNAME=.*/K8S_HOSTNAME=k8s-control-plane-002/' bootstrap/k8s-node/.env
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-control-plane-002 --cpus 4 --memory 8192
```

> **Note**: Get the certificate key from an existing control plane node:
> ```bash
> sudo kubeadm init phase upload-certs --upload-certs
> ```

**Inside the VM**, after reboot completes:

```bash
bash kubeadm/init-node.sh
bash kubeadm/join-control-plane.sh \
    --token <token> \
    --hash sha256:<hash> \
    --endpoint <control-plane-ip>:6443 \
    --certificate-key <key>
```

### Infrastructure Deployments

Copy the `infrastructure/` directory to a control plane node:

```bash
scp -r infrastructure core@<control-plane-ip>:~/
ssh core@<control-plane-ip>
```

#### Storage (NFS CSI)

```bash
# Deploy csi-driver-nfs and create the StorageClass
bash infrastructure/storage-nfs/install.sh
```

#### GPU (NVIDIA Operator)

Requires GPU worker nodes already joined to the cluster. Deploys Node Feature Discovery (NFD), container toolkit, and device plugin — only on nodes with NVIDIA GPUs.

```bash
# Deploy GPU operator with host driver reuse + CDI
bash infrastructure/gpu-operator/install.sh

# Verify (only GPU nodes show nvidia.com/gpu labels)
kubectl get nodes --show-labels | grep nvidia.com/gpu
```

## Important Notes

- **DHCP IP**: VMs get dynamic IPs from the default network (bridge `virbr0`). Reboots may change the address, breaking the control plane endpoint. Set a static DHCP lease or use `virsh net-update` to pin the MAC to an IP.
- **Token expiry**: `kubeadm token create` tokens expire after 24 hours. Regenerate if needed.
- **Hostname resolution**: If using a hostname for `--endpoint` (e.g. `control-plane.k8s.junjie.pro`), ensure it resolves on every node via DNS or `/etc/hosts`.
- **NFSv4 + FCOS**: FCOS requires `fsid=0` on the NFS export to establish the NFSv4 pseudofilesystem root. Without it, NFSv4 clients silently fall back to NFSv3 because the server cannot traverse `/var` (separate bind-mounted filesystem on FCOS). With `fsid=0`, the export becomes the NFSv4 root — the CSI StorageClass must use `share: /` (not `/var/nfs-data`) since the mount path is relative to the pseudoroot. `subDir` subdirectories are created under the physical export path normally.

## Reference

### `bootstrap/vm-deploy.sh` Options

| Option           | Default                    | Description            |
|------------------|----------------------------|------------------------|
| `--type`         | — (required)               | Node type: `k8s-node`, `k8s-gpu-node`, or `storage-server` |
| `--name`         | `k8s-control-plane-001`    | Libvirt domain name    |
| `--cpus`         | `2`                        | vCPUs                  |
| `--memory`       | `4096`                     | Memory in MiB          |
| `--disk-size`    | `64`                       | Disk in GiB            |
| `--image`        | auto-detect                | FCOS QCOW2 path        |
| `--network`      | `virbr0`                   | Bridge name            |
| `--os-variant`   | `fedora-coreos-stable`     | osinfo variant         |
| `--no-blockpull` | off                        | Skip backing file pull |
| `--dry-run`      | off                        | Print command only     |

### `bootstrap/vm-image-upload.sh` Options

| Option    | Default        | Description        |
|-----------|----------------|--------------------|
| `--pool`  | `default`      | Storage pool name  |
| `--name`  | image basename | Volume name in pool |
| `--format`| `raw`          | Volume format      |

### `bootstrap/k8s-node/build.sh` Options

| Option       | Description                    |
|--------------|--------------------------------|
| `--validate` | Validate template, no output   |

### `bootstrap/kubeadm/init-control-plane.sh` Options

| Option              | Required | Default                               | Description                         |
|---------------------|----------|---------------------------------------|-------------------------------------|
| `--endpoint`        | no       | `control-plane.k8s.junjie.pro:6443`   | API server endpoint                 |
| `--config`          | no       | `bootstrap/kubeadm/kubeadm-init.yaml` | kubeadm config template             |
| `--configure-kubectl`| no      | off                                   | Copy admin.conf to `~/.kube/config` |
| `--install-cni`     | no       | off                                   | Run Cilium install after init       |
| `--cni-version`     | no       | `1.19.4`                              | Cilium version                      |
| `--pod-cidr`        | no       | `172.16.0.0/12`                       | Pod IPv4 CIDR                       |
| `--dry-run`         | no       | off                                   | Print generated config and commands |

### `bootstrap/kubeadm/join-worker.sh` Options

| Option       | Required | Default                                        | Description        |
|--------------|----------|------------------------------------------------|--------------------|
| `--token`    | yes      | —                                              | Bootstrap token    |
| `--hash`     | yes      | —                                              | CA cert hash       |
| `--endpoint` | yes      | —                                              | API server endpoint|
| `--config`   | no       | `bootstrap/kubeadm/kubeadm-join-worker.yaml`   | Join config template|
| `--dry-run`  | no       | off                                            | Print generated config and commands |

### `bootstrap/kubeadm/join-control-plane.sh` Options

| Option              | Required | Default                                               | Description               |
|---------------------|----------|-------------------------------------------------------|---------------------------|
| `--token`           | yes      | —                                                     | Bootstrap token           |
| `--hash`            | yes      | —                                                     | CA cert hash              |
| `--endpoint`        | yes      | —                                                     | API server endpoint       |
| `--certificate-key` | yes      | —                                                     | Certificate key           |
| `--config`          | no       | `bootstrap/kubeadm/kubeadm-join-control-plane.yaml`   | Join config template      |
| `--dry-run`         | no       | off                                                   | Print generated config and commands |

### `infrastructure/network-cilium/install.sh` Options

| Option      | Default              | Description                  |
|-------------|----------------------|------------------------------|
| `--version` | `1.19.4`             | Cilium version               |
| `--cidr`    | `172.16.0.0/12`      | Pod IPv4 CIDR                |
| `--lb-cidr` | auto-detect          | LB-IPAM pool CIDR            |
| `--dry-run` | off                  | Print commands only          |

### `infrastructure/gpu-operator/install.sh` Options

| Option      | Default       | Description                  |
|-------------|---------------|------------------------------|
| `--version` | `""` (latest) | GPU Operator Helm chart ver  |
| `--dry-run` | off           | Print command only           |

### `.env` Variables

#### `bootstrap/k8s-node/.env`

| Variable                     | Description                                               |
|------------------------------|-----------------------------------------------------------|
| `K8S_PASSWORD_HASH`          | `openssl passwd -6` output                                |
| `K8S_SSH_PUB_KEY`            | SSH public key for core user                              |
| `K8S_HOSTNAME`               | OS hostname (default: `k8s-control-plane-001`)            |
| `K8S_PREINSTALLED_PACKAGES`  | rpm-ostree packages (default: `"cri-o1.35 kubernetes1.35"`) |

#### `bootstrap/k8s-gpu-node/.env`

| Variable                 | Description                                               |
|--------------------------|-----------------------------------------------------------|
| `K8S_PASSWORD_HASH`      | `openssl passwd -6` output                                |
| `K8S_SSH_PUB_KEY`        | SSH public key for core user                              |
| `K8S_HOSTNAME`           | OS hostname (default: `k8s-gpu-worker-001`)               |
| `K8S_PREINSTALLED_PACKAGES` | rpm-ostree packages (default: `"cri-o1.35 kubernetes1.35"`) |
| `K8S_GPU_DEVICES`        | PCI addresses for passthrough (e.g. `"0000:01:00.0 0000:01:00.1"`) |
| `K8S_VIRTIOFS_SOURCE`    | Host directory for virtiofs passthrough                   |
| `K8S_VIRTIOFS_TARGET`    | Guest mount tag (default: `hf_hub`)                       |

#### `bootstrap/storage-server/.env`

| Variable                | Description                                      |
|-------------------------|--------------------------------------------------|
| `K8S_PASSWORD_HASH`     | `openssl passwd -6` output                       |
| `K8S_SSH_PUB_KEY`       | SSH public key for core user                     |
| `K8S_HOSTNAME`          | OS hostname (default: `k8s-storage-001`)         |
| `PREINSTALLED_PACKAGES` | rpm-ostree packages (default: `nfs-utils`)       |
