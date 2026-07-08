# Infrastructure

Cluster-level services deployed on the control plane via Kustomize.
Each component has a `kustomization.yaml` — use `--help` or see the
kustomization for version/configuration details.

## Components

### network-cilium

Cilium CNI with Gateway API + kube-proxy replacement. Installs Gateway API
CRDs, creates LB-IPAM pool, and enables L2 announcements. Uses `cilium` CLI
(not kustomize) due to complex multi-step setup.

```bash
bash infrastructure/network-cilium/install.sh
bash infrastructure/network-cilium/install.sh --version 1.19.4 --cidr 172.16.0.0/12
```

### cert-manager

```bash
kubectl kustomize --enable-helm infrastructure/cert-manager/ | kubectl apply -f -
```

Requires `.env` with Cloudflare API token (copy from `.env.example`).
Default ClusterIssuer targets Let's Encrypt production. To use staging,
swap `clusterissuer.yaml` for `clusterissuer-staging.yaml` in
`kustomization.yaml` resources.

### external-dns

```bash
kubectl apply -k infrastructure/external-dns/
```

Requires `.env` with Cloudflare API token (copy from `.env.example`).

### gpu-operator

```bash
kubectl kustomize --enable-helm infrastructure/gpu-operator/ | kubectl apply -f -
```

### metrics-server

```bash
kubectl kustomize --enable-helm infrastructure/metrics-server/ | kubectl apply -f -
```

### storage-nfs

```bash
kubectl kustomize --enable-helm infrastructure/storage-nfs/ | kubectl apply -f -
```
