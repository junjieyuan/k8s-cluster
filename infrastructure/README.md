# Infrastructure

Cluster-level services deployed on the control plane via `kubectl`/`helm`.
Each component has an `install.sh` entry point — run with `--help` for full
options. All scripts can be invoked from any directory.

## Components

### network-cilium

Cilium CNI with Gateway API + kube-proxy replacement. Installs Gateway API
CRDs, creates LB-IPAM pool, and enables L2 announcements.

```bash
bash infrastructure/network-cilium/install.sh
bash infrastructure/network-cilium/install.sh --version 1.19.4 --cidr 172.16.0.0/12
```

### storage-nfs

csi-driver-nfs via Helm. Requires an NFS server with `fsid=0` export (FCOS
NFSv4 requirement — see README "Important Notes").

```bash
bash infrastructure/storage-nfs/install.sh --server storage-001.k8s.junjie.pro
```

### gpu-operator

NVIDIA GPU Operator via Helm. Deploys NFD, container toolkit, and device
plugin with host driver reuse + CDI. Requires GPU worker nodes joined to the
cluster.

```bash
bash infrastructure/gpu-operator/install.sh
```

### cert-manager

cert-manager via Helm with Let's Encrypt DNS-01 ClusterIssuers
(Cloudflare). Supports wildcard certificates.

```bash
bash infrastructure/cert-manager/install.sh --email <email> --cf-token <token>
bash infrastructure/cert-manager/install.sh --email <email> --cf-token <token> --staging
```

### external-dns

Syncs Gateway API hostnames to Cloudflare DNS.

```bash
bash infrastructure/external-dns/install.sh --cf-token <token>
```

### metrics-server

Resource metrics for `kubectl top` and HPA via Helm.

```bash
bash infrastructure/metrics-server/install.sh
```
