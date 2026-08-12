# Infrastructure

Cluster-level services deployed on the control plane via Kustomize.
Each component has a `kustomization.yaml` — see it for version and
configuration details.

## Components

### network-cilium

Cilium CNI with Gateway API + kube-proxy replacement. Installs Gateway API
CRDs, creates LB-IPAM pool, and enables L2 announcements. Uses `cilium` CLI
(not kustomize) due to complex multi-step setup.

```bash
bash infrastructure/network-cilium/install.sh
bash infrastructure/network-cilium/install.sh --version 1.19.6 --cidr 172.16.0.0/12
```

### cert-manager

```bash
kubectl kustomize --enable-helm infrastructure/cert-manager/ | kubectl apply -f -
```

Requires `.env` with Cloudflare API token (copy from `.env.example`).

Proxying is the global default: `extraArgs.cloudflare-proxied: true` in
`infrastructure/external-dns/values.yaml` means every DNSEndpoint record is
proxied (orange cloud). Per-record overrides (e.g. DNS-only) are declared on
the app side in `k8s-apps` DNSEndpoints with `providerSpecific` using the full
annotation key `external-dns.alpha.kubernetes.io/cloudflare-proxied` and the
string value `"true"`/`"false"` (not a YAML boolean). TXT/MX/NS/SPF/SRV/LOC
records are never proxied.

### external-dns

```bash
kubectl kustomize --enable-helm infrastructure/external-dns/ | kubectl apply -f -
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
