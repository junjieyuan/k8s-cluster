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
│   ├── build-ignition.sh                   # [host] Compile Butane template -> Ignition config
│   ├── k8s-node/
│   │   ├── node.bu.tmpl                    # [host] Butane template (user, hostname, packages)
│   │   └── .env.example                    # [host] Configuration template
│   ├── k8s-gpu-node/
│   │   ├── deploy.sh                       # [host] GPU-specific deploy (PCI passthrough, virtiofs)
│   │   ├── gpu-worker.bu.tmpl              # [host] Butane template (user, hostname)
│   │   └── .env.example                    # [host] Configuration template (GPU PCI, virtiofs)
│   ├── storage-server/
│   │   ├── storage.bu.tmpl                 # [host] Butane template (NFS exports, packages)
│   │   └── .env.example                    # [host] Configuration template
│   └── kubeadm/
│       ├── init-node.sh                    # [vm]  Kernel modules, sysctl, disable zram swap, enable CRI-O/kubelet
│       ├── init-control-plane.sh           # [vm]  kubeadm init + optional kubectl setup
│       ├── join-worker.sh                  # [vm]  kubeadm join for worker nodes
│       ├── join-control-plane.sh           # [vm]  kubeadm join for control plane nodes
│       ├── kubeadm-init.yaml               # [vm]  kubeadm InitConfiguration + ClusterConfiguration
│       ├── kubeadm-join-worker.yaml        # [vm]  kubeadm JoinConfiguration template (worker)
│       └── kubeadm-join-control-plane.yaml # [vm]  kubeadm JoinConfiguration template (control plane)
├── docs/
│   ├── cilium-gateway.md                     # Cilium Gateway API best practices
│   ├── control-plane-upgrade.md              # Control plane node upgrade guide
│   ├── deployment-checklist.md               # Pre/post-deployment verification checklist
│   ├── gpu-worker-upgrade.md                 # GPU worker node upgrade guide
│   └── worker-upgrade.md                     # Worker node upgrade guide
└── infrastructure/
    ├── cilium/
    │   ├── pre-apply.sh                    # [host] Gateway API CRD bootstrap (before apply)
    │   ├── kustomization.yaml              # Cilium chart (helmCharts, pinned version)
    │   ├── values.yaml                     # Chart overrides (Gateway API, LB-IPAM, L2)
    │   ├── loadbalancer-ippool.yaml        # LB-IPAM pool (CIDR 192.168.200.0/24)
    │   └── l2-announcement-policy.yaml     # L2 ARP responder for external LB access
    ├── csi-driver-nfs/
    │   ├── kustomization.yaml              # csi-driver-nfs chart (helmCharts)
    │   └── storage-class.yaml              # Default NFS StorageClass
    ├── gpu-operator/
    │   ├── kustomization.yaml              # GPU operator chart (helmCharts)
    │   ├── namespace.yaml                  # gpu-operator namespace
    │   └── values.yaml                     # Helm values (host driver reuse, CDI)
    ├── cert-manager/
    │   ├── kustomization.yaml              # cert-manager chart (helmCharts)
    │   ├── values.yaml                     # Helm values (CRD management, DNS config)
    │   ├── namespace.yaml                  # cert-manager namespace
    │   └── clusterissuer.yaml              # Let's Encrypt production ClusterIssuer
    ├── external-dns/
    │   ├── kustomization.yaml              # external-dns chart (helmCharts)
    │   ├── values.yaml                     # Helm values (Cloudflare, proxied default)
    │   ├── namespace.yaml                  # external-dns namespace
    │   └── deploy.sh                       # [host] DNSEndpoint CRD bootstrap + apply
    └── metrics-server/
        ├── kustomization.yaml              # metrics-server chart (helmCharts)
        └── values.yaml                     # Helm values (kubelet-insecure-tls)
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
- `yamlfmt` (google/yamlfmt) — formats YAML as KYAML (see Conventions)

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
#   K8S_SSH_PUB_KEYS=<one key per line, multi-line value>
#   Other vars (K8S_HOSTNAME, K8S_PREINSTALLED_PACKAGES) have defaults

# For GPU workers (optional)
cp bootstrap/k8s-gpu-node/.env.example bootstrap/k8s-gpu-node/.env
# Edit .env:
#   K8S_PASSWORD_HASH=<run: openssl passwd -6>
#   K8S_SSH_PUB_KEYS=<one key per line, multi-line value>
#   K8S_GPU_DEVICES="0000:01:00.0 0000:01:00.1"  # lspci -nn | grep -i nvidia
#   K8S_VIRTIOFS_SOURCE="/home/<user>/.cache/huggingface/hub"

# For storage server (optional)
cp bootstrap/storage-server/.env.example bootstrap/storage-server/.env
# Edit .env:
#   K8S_PASSWORD_HASH=<run: openssl passwd -6>
#   K8S_SSH_PUB_KEYS=<one key per line, multi-line value>
```

#### 3. Build Ignition Config

`vm-deploy.sh --type` auto-builds during deployment, but you can also build manually:

```bash
# K8s node
bash bootstrap/build-ignition.sh --template bootstrap/k8s-node/node.bu.tmpl              # generates bootstrap/k8s-node/node.ign
bash bootstrap/build-ignition.sh --template bootstrap/k8s-node/node.bu.tmpl --validate   # validate only, no output

# GPU worker
bash bootstrap/build-ignition.sh --template bootstrap/k8s-gpu-node/gpu-worker.bu.tmpl          # generates bootstrap/k8s-gpu-node/gpu-worker.ign

# Storage server
bash bootstrap/build-ignition.sh --template bootstrap/storage-server/storage.bu.tmpl        # generates bootstrap/storage-server/storage.ign
```

#### 4. Provision VMs

`--cpus`, `--memory`, `--disk-size` are optional when `K8S_CPUS`/`K8S_MEMORY`/`K8S_DISK_SIZE`
are set in the type's `.env`. CLI flags override `.env` values.

```bash
# Control plane (defaults from .env: 2 vCPUs / 4 GiB / 64 GiB)
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-control-plane-001
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-control-plane-002 --cpus 4 --memory 8192

# GPU worker (defaults from .env: 16 vCPUs / 32 GiB / 64 GiB, PCI passthrough + virtiofs)
bash bootstrap/vm-deploy.sh --type k8s-gpu-node --name k8s-gpu-worker-001

# Storage server (defaults from .env: 2 vCPUs / 4 GiB / 128 GiB)
bash bootstrap/vm-deploy.sh --type storage-server --name k8s-storage-001

# Dry-run
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-control-plane-001 --dry-run
```

The VM boots, applies Ignition config (including rpm-ostree install of cri-o + kubernetes), and reboots. Wait ~2-3 minutes for the reboot to complete.

For k8s-gpu-node type, the Ignition config follows [ublue's autorebase pattern](https://github.com/ublue-os/ucore#auto-rebase-install). Three reboots happen automatically:

1. **Unsigned rebase**: FCOS → `ucore-minimal:stable-nvidia` (unsigned) → reboot
2. **Signed rebase**: switch to signed image for verified updates → reboot
3. **Install k8s**: layer cri-o + kubernetes on uCore → reboot

No manual steps needed — after all reboots (~6-7 min), the VM is running signed uCore NVIDIA with k8s installed. GPU passthrough, virtiofs, host-passthrough CPU, and memory backing are all configured in the domain XML before the VM ever boots.

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
bash kubeadm/init-control-plane.sh --configure-kubectl
# Or with a custom endpoint:
# bash kubeadm/init-control-plane.sh --endpoint 192.168.122.100:6443 --configure-kubectl
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
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-worker-001 --cpus 2 --memory 4096 --disk-size 64
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
bash bootstrap/vm-deploy.sh --type k8s-node --name k8s-control-plane-002 --cpus 4 --memory 8192 --disk-size 64
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

Copy `infrastructure/` to a control plane node and deploy cluster-level services (Cilium CNI, NFS CSI, GPU Operator, cert-manager, external-dns, metrics-server). See [`infrastructure/README.md`](infrastructure/README.md) for details.

```bash
scp -r infrastructure core@<control-plane-ip>:~/
ssh core@<control-plane-ip>
bash infrastructure/cilium/pre-apply.sh
kubectl kustomize --enable-helm infrastructure/cilium/ | kubectl apply -f -
kubectl kustomize --enable-helm infrastructure/cert-manager/ | kubectl apply -f -
# external-dns: run deploy.sh first (DNSEndpoint CRD from the cached chart)
# ... each component: kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -
```

## Conventions

### YAML is KYAML

Every YAML file in this repo is written in **KYAML**, the flow-style YAML
dialect proposed in [KEP 5295](https://www.kubernetes.dev/resources/keps/5295/):
`---` header, `{}` for maps, `[]` for lists, double-quoted strings, trailing
commas. KYAML is valid YAML, so `kubectl apply` and
`kubectl kustomize --enable-helm` workflows are unchanged. Kubeadm configs
keep their `${VAR}` placeholders — they are envsubst templates by design.

Format with Google's `yamlfmt` (the repo-root `.yamlfmt` config enables the
kyaml formatter):

```bash
yamlfmt -dry <file>   # preview without modifying
yamlfmt <file>        # format in place
yamlfmt -lint <dir>/  # enforce (CI-friendly)
```

## Upgrades

For replacing nodes with newer versions, see the guides in [`docs/`](docs/):

- [`docs/control-plane-upgrade.md`](docs/control-plane-upgrade.md)
- [`docs/worker-upgrade.md`](docs/worker-upgrade.md)
- [`docs/gpu-worker-upgrade.md`](docs/gpu-worker-upgrade.md)

## Important Notes

- **DHCP IP**: VMs get dynamic IPs from the default network (bridge `virbr0`). Reboots may change the address, breaking the control plane endpoint. Set a static DHCP lease or use `virsh net-update` to pin the MAC to an IP.
- **Token expiry**: `kubeadm token create` tokens expire after 24 hours. Regenerate if needed.
- **Hostname resolution**: If using a hostname for `--endpoint` (e.g. `control-plane.k8s.junjie.pro`), ensure it resolves on every node via DNS or `/etc/hosts`.
- **NFSv4 + FCOS**: FCOS requires `fsid=0` on the NFS export to establish the NFSv4 pseudofilesystem root. Without it, NFSv4 clients silently fall back to NFSv3 because the server cannot traverse `/var` (separate bind-mounted filesystem on FCOS). With `fsid=0`, the export becomes the NFSv4 root — the CSI StorageClass must use `share: /` (not `/var/nfs`) since the mount path is relative to the pseudoroot. `subDir` subdirectories are created under the physical export path normally.
