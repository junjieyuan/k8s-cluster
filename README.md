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
│   │   ├── node.bu.tmpl                    # [host] Butane template (user, hostname, kernel, packages)
│   │   └── .env.example                    # [host] Configuration template
│   ├── storage-server/
│   │   ├── build.sh                        # [host] Compile storage Butane template -> Ignition config
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
    └── storage-nfs/
        ├── install.sh                      # [vm]  Deploy csi-driver-nfs via Helm
        └── storage-class.yaml              # [vm]  NFS StorageClass definition
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
#   Other vars (K8S_HOSTNAME, K8S_CRIO_VERSION, K8S_KUBERNETES_VERSION) have defaults

# For storage server (optional)
cp bootstrap/storage-server/.env.example bootstrap/storage-server/.env
# Edit .env:
#   K8S_PASSWORD_HASH=<run: openssl passwd -6>
#   K8S_SSH_PUB_KEY=<your public key>
```

#### 3. Build Ignition Config

`--type` auto-builds during deployment, but you can also build manually:

```bash
# K8s node
bash bootstrap/k8s-node/build.sh              # generates bootstrap/k8s-node/node.ign
bash bootstrap/k8s-node/build.sh --validate   # validate only, no output

# Storage server (optional)
bash bootstrap/storage-server/build.sh         # generates bootstrap/storage-server/storage.ign
```

#### 4. Provision VMs

Use `--type` for a one-step build + deploy, or `--ignition` for a pre-built config:

```bash
# Control plane (auto-builds + deploys)
bash bootstrap/vm-deploy.sh --type k8s-node
bash bootstrap/vm-deploy.sh --type k8s-node --cpus 4 --memory 8192

# Storage server (auto-builds + deploys)
bash bootstrap/vm-deploy.sh --type storage-server --name k8s-storage-001

# Dry-run
bash bootstrap/vm-deploy.sh --type k8s-node --dry-run
```

The VM boots, applies Ignition config, installs packages via rpm-ostree, and reboots. Wait ~2-3 minutes for the reboot to complete.

### Inside the VM

Copy the `bootstrap/kubeadm/` directory to the VM, then SSH in.

```bash
# Find the VM IP
sudo virsh net-dhcp-leases default

# Copy kubeadm scripts to the VM
scp -r bootstrap/kubeadm/ core@<vm-ip>:~/

# SSH in
ssh core@<vm-ip>
```

#### 5. Initialize Control Plane

**Inside the VM**, after the first reboot completes (~2-3 min):

```bash
bash bootstrap/kubeadm/init-node.sh
bash bootstrap/kubeadm/init-control-plane.sh --configure-kubectl --install-cni
# Or with a custom endpoint:
# bash bootstrap/kubeadm/init-control-plane.sh --endpoint 192.168.122.100:6443 --configure-kubectl --install-cni
```

> **Note**: Use the VM's IP as the endpoint, and update DNS/hosts:
> ```bash
> echo '<control-plane-ip> control-plane.k8s.junjie.pro' | sudo tee -a /etc/hosts
> ```

#### 6. Add Worker Nodes (Optional)

**On the Host** — get join token, then provision the worker:

```bash
# Get join info from control plane
ssh core@<control-plane-ip> sudo kubeadm token create --print-join-command
# Output: "kubeadm join <endpoint> --token xxx --discovery-token-ca-cert-hash sha256:xxx"

# Edit .env, set hostname, rebuild Ignition
sed -i 's/^K8S_HOSTNAME=.*/K8S_HOSTNAME=k8s-worker-001/' bootstrap/k8s-node/.env

# Provision worker VM (--type auto-builds + deploys)
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-worker-001 --cpus 2 --memory 4096
```

> **NVIDIA GPU workers**: For nodes with GPUs, after the initial install reboots and before joining:
>
> ```bash
> # SSH in, switch to ublue OS image which includes NVIDIA drivers
> sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/ublue-os/ucore-minimal:stable-nvidia
> # Reboot into the new image, then join as described below
> ```
>
> Ublue enables firewalld and zram swap by default. These are handled automatically:
> - `init-node.sh` disables zram swap (stop + mask `systemd-zram-setup@zram0.service`)
> - `join-worker.sh` opens firewalld ports via `kube-worker` service

**Inside the VM**, after (optional) GPU switch and reboot:

```bash
bash bootstrap/kubeadm/init-node.sh
bash bootstrap/kubeadm/join-worker.sh \
    --token <token> \
    --hash sha256:<hash> \
    --endpoint <control-plane-ip>:6443
```

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
bash bootstrap/kubeadm/init-node.sh
bash bootstrap/kubeadm/join-control-plane.sh \
    --token <token> \
    --hash sha256:<hash> \
    --endpoint <control-plane-ip>:6443 \
    --certificate-key <key>
```

### Infrastructure Deployments

Copy the `infrastructure/` directory to a control plane node:

```bash
scp -r infrastructure/ core@<control-plane-ip>:~/
ssh core@<control-plane-ip>
```

#### Storage (NFS CSI)

```bash
# Deploy csi-driver-nfs and create the StorageClass
bash infrastructure/storage-nfs/install.sh
```

## Important Notes

- **DHCP IP**: VMs get dynamic IPs from the default network (bridge `virbr0`). Reboots may change the address, breaking the control plane endpoint. Set a static DHCP lease or use `virsh net-update` to pin the MAC to an IP.
- **Token expiry**: `kubeadm token create` tokens expire after 24 hours. Regenerate if needed.
- **Hostname resolution**: If using a hostname for `--endpoint` (e.g. `control-plane.k8s.junjie.pro`), ensure it resolves on every node via DNS or `/etc/hosts`.

## Reference

### `bootstrap/vm-deploy.sh` Options

| Option           | Default                    | Description            |
|------------------|----------------------------|------------------------|
| `--type`         | —                          | Node type: `k8s-node` or `storage-server` (auto-builds + deploys) |
| `--ignition`     | —                          | Path to .ign file (skip build, deploy only) |
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

| Option      | Default       | Description             |
|-------------|---------------|-------------------------|
| `--version` | `1.19.4`      | Cilium version          |
| `--cidr`    | `172.16.0.0/12`| Pod IPv4 CIDR           |
| `--dry-run` | off           | Print command only      |

### `bootstrap/k8s-node/.env` Variables

| Variable                 | Description                                      |
|--------------------------|--------------------------------------------------|
| `K8S_PASSWORD_HASH`      | `openssl passwd -6` output                       |
| `K8S_SSH_PUB_KEY`        | SSH public key for core user                     |
| `K8S_HOSTNAME`           | OS hostname (default: `k8s-control-plane-001`)   |
| `K8S_CRIO_VERSION`       | CRI-O rpm-ostree package (default: `cri-o1.35`)  |
| `K8S_KUBERNETES_VERSION` | Kubernetes rpm-ostree package (default: `kubernetes1.35`) |

### `bootstrap/storage-server/.env` Variables

| Variable              | Description                                      |
|-----------------------|--------------------------------------------------|
| `K8S_PASSWORD_HASH`   | `openssl passwd -6` output                       |
| `K8S_SSH_PUB_KEY`     | SSH public key for core user                     |
| `K8S_HOSTNAME`        | OS hostname (default: `k8s-storage-001`)         |
| `PREINSTALLED_PACKAGES`| rpm-ostree packages (default: `nfs-utils`)       |
