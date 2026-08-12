# Infrastructure

Cluster-level services deployed on the control plane via Kustomize.
Each component has a `kustomization.yaml` — see it for version and
configuration details.

## Components

### network-cilium

Cilium CNI with Gateway API + kube-proxy replacement. The chart, LB-IPAM pool,
and L2 policy are deployed via Kustomize (version pinned in
`kustomization.yaml`, pool CIDR in `loadbalancer-ippool.yaml`); `pre-apply.sh`
bootstraps Gateway API CRDs from the upstream release URL. Cilium CRDs are
registered by cilium-operator at startup — no cilium CLI needed.

```bash
bash infrastructure/network-cilium/pre-apply.sh
kubectl kustomize --enable-helm infrastructure/network-cilium/ | kubectl apply -f -
# fresh cluster: run the apply twice — operator registers Cilium CRDs between runs
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

`deploy.sh` bootstraps the DNSEndpoint CRD from the cached chart, then applies:

```bash
bash infrastructure/external-dns/deploy.sh
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
