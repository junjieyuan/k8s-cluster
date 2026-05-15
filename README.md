# k8s-cluster

Provision a Kubernetes cluster on Fedora CoreOS VMs using libvirt + Butane/Ignition + kubeadm + Cilium.

## Overview

- **Runtime**: CRI-O
- **CNI**: Cilium (cluster-pool IPAM, default `172.16.0.0/12`)
- **OS**: Fedora CoreOS (immutable, updated via rpm-ostree at first boot)
- **Hypervisor**: libvirt/KVM with QCOW2 backing images

### Files

```
├── core-install.sh          # [host]  Provision FCOS VMs via virt-install
├── upload-image.sh          # [host]  Upload disk image to libvirt storage pool
├── butane/
│   ├── build.sh             # [host]  Compile Butane template → Ignition config
│   ├── node.bu.tmpl         # [host]  Butane template (user, hostname, kernel, packages)
│   └── .env.example         # [host]  Configuration template
└── init/
    ├── init-node.sh         # [vm]    Kernel modules, sysctl, enable CRI-O/kubelet
    ├── init-control-plane.sh # [vm]   kubeadm init + optional Cilium install
    ├── join-worker.sh        # [vm]   kubeadm join for worker nodes
    ├── join-control-plane.sh # [vm]   kubeadm join for additional control plane nodes
    ├── cilium.sh             # [vm]   Install Cilium CNI
    ├── kubeadm-init.yaml     # [vm]   kubeadm InitConfiguration + ClusterConfiguration
    ├── kubeadm-join-worker.yaml          # [vm]   kubeadm JoinConfiguration template (worker)
    └── kubeadm-join-control-plane.yaml   # [vm]   kubeadm JoinConfiguration template (control plane)
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

### On the Host

#### 1. Download and Upload FCOS Image

```bash
# Download latest stable FCOS QCOW2
curl -LO https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/latest/x86_64/fedora-coreos-qemu.x86_64.qcow2

# Upload to libvirt default storage pool (SHA512-verified)
bash upload-image.sh fedora-coreos-*.qcow2
```

#### 2. Configure Credentials

```bash
cp butane/.env.example butane/.env
# Edit .env:
#   PASSWORD_HASH=<run: openssl passwd -6>
#   SSH_PUB_KEY=<your public key>
#   HOSTNAME=k8s-control-plane-001
```

#### 3. Build Ignition Config

```bash
bash butane/build.sh          # generates butane/node.ign
bash butane/build.sh --validate  # validate only, no output
```

#### 4. Provision Control Plane VM

```bash
bash core-install.sh                          # defaults
bash core-install.sh --cpus 4 --memory 8192   # recommended for control plane
bash core-install.sh --dry-run                # preview without executing
```

The VM boots, applies Ignition config, installs CRI-O and Kubernetes via rpm-ostree, and reboots. Wait ~2-3 minutes for the reboot to complete.

### Inside the VM

Copy the `init/` directory to the VM, then SSH in.

```bash
# Find the VM IP
virsh net-dhcp-leases virbr0

# Copy init scripts to the VM
scp -r init/ core@<vm-ip>:~/

# SSH in
ssh core@<vm-ip>
```

#### 5. Initialize Control Plane

```bash
bash init/init-node.sh
sudo bash init/init-control-plane.sh --configure-kubectl --install-cni
# Or with a custom endpoint:
# sudo bash init/init-control-plane.sh --endpoint 192.168.122.100:6443 --configure-kubectl --install-cni
```

> **Note**: Use the VM's IP (from `virsh net-dhcp-leases virbr0`) as the endpoint. If you prefer a hostname like `control-plane.k8s.junjie.pro`, add it to `/etc/hosts` on every node first:
> ```bash
> echo '<control-plane-ip> control-plane.k8s.junjie.pro' | sudo tee -a /etc/hosts
> ```

#### 6. Add Worker Nodes (Optional)

**On the Host** — get join token from control plane, then provision worker:

```bash
# Get join info from control plane (run via SSH or on control plane VM)
# Token expires after 24h — regenerate with the same command if needed.
ssh core@<control-plane-ip> sudo kubeadm token create --print-join-command
# Output: kubeadm join <endpoint> --token xxx --discovery-token-ca-cert-hash sha256:xxx

# Edit .env, set HOSTNAME=k8s-worker-001, rebuild Ignition
sed -i 's/^HOSTNAME=.*/HOSTNAME=k8s-worker-001/' butane/.env
bash butane/build.sh

# Provision worker VM
bash core-install.sh --name k8s-worker-001 --cpus 2 --memory 4096
```

**Inside the VM** — copy init scripts, SSH in, then join:

```bash
scp -r init/ core@<worker-ip>:~/
ssh core@<worker-ip>
bash init/init-node.sh
bash init/join-worker.sh \
    --token <token> \
    --hash sha256:<hash> \
    --endpoint <control-plane-ip>:6443
```

## Important Notes

- **DHCP IP**: VMs get dynamic IPs from `virbr0`. Reboots may change the address, breaking the control plane endpoint. Set a static DHCP lease or use `virsh net-update` to pin the MAC to an IP.
- **Token expiry**: `kubeadm token create` tokens expire after 24 hours. Regenerate if needed.
- **Hostname resolution**: If using a hostname for `--endpoint` (e.g. `control-plane.k8s.junjie.pro`), ensure it resolves on every node via DNS or `/etc/hosts`.

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

### `init/init-control-plane.sh` Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `--endpoint` | no | `control-plane.k8s.junjie.pro:6443` | API server endpoint |
| `--config` | no | `init/kubeadm-init.yaml` | kubeadm config template |
| `--configure-kubectl` | no | off | Copy admin.conf to `~/.kube/config` |
| `--install-cni` | no | off | Run cilium.sh after init |
| `--cni-version` | no | `1.19.4` | Cilium version |
| `--pod-cidr` | no | `172.16.0.0/12` | Pod IPv4 CIDR |
| `--dry-run` | no | off | Print generated config and commands |

### `init/join-worker.sh` Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `--token` | yes | — | Bootstrap token |
| `--hash` | yes | — | CA cert hash, e.g. `sha256:abc123...` |
| `--endpoint` | yes | — | API server endpoint |
| `--config` | no | `init/kubeadm-join-worker.yaml` | Join config template |
| `--dry-run` | no | off | Print generated config and commands |

### `init/join-control-plane.sh` Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `--token` | yes | — | Bootstrap token |
| `--hash` | yes | — | CA cert hash, e.g. `sha256:abc123...` |
| `--endpoint` | yes | — | API server endpoint |
| `--certificate-key` | yes | — | Certificate key from `kubeadm init phase upload-certs` |
| `--config` | no | `init/kubeadm-join-control-plane.yaml` | Join config template |
| `--dry-run` | no | off | Print generated config and commands |

### `init/cilium.sh` Options

| Option | Default | Description |
|--------|---------|-------------|
| `--version` | `1.19.4` | Cilium version |
| `--cidr` | `172.16.0.0/12` | Pod IPv4 CIDR |
| `--dry-run` | off | Print command only |

### `.env` Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PASSWORD_HASH` | yes | — | `openssl passwd -6` output |
| `SSH_PUB_KEY` | yes | — | SSH public key for core user |
| `HOSTNAME` | no | `k8s-control-plane-001` | OS hostname |
| `CRIO_VERSION` | no | `cri-o1.35` | CRI-O rpm-ostree package |
| `KUBERNETES_VERSION` | no | `kubernetes1.35` | Kubernetes rpm-ostree package |
