# Cilium Gateway API

This repo uses Cilium as CNI with kube-proxy replacement and Gateway API.
These are the rules and known issues collected from operational experience.

---

## Infrastructure best practices

- **Gateway API over Ingress** — expose services via `Gateway` + `HTTPRoute`
  (`gateway.networking.k8s.io/v1`). Do not use `networking.k8s.io/v1` Ingress
  or Cilium Ingress CRDs.
- **LB-IPAM** — always create a `CiliumLoadBalancerIPPool` for bare-metal
  environments. No manual external IP assignment.
- **L2 announcements** — enable in bare-metal environments for external LB
  access. Requires RBAC patch on `clusterrole cilium` for `leases` resource.
- **kube-proxy replacement** — mandatory for Gateway API. Cilium handles
  service routing via eBPF.

---

## Install / upgrade

Run `infrastructure/network-cilium/pre-apply.sh` to install Gateway API CRDs,
then deploy the chart via kustomize
(`kubectl kustomize --enable-helm infrastructure/network-cilium/ |
kubectl apply -f -`). On a fresh cluster, run the kustomize apply twice —
cilium-operator registers Cilium CRDs between the runs. When enabling Gateway
API on an existing cluster, the manual steps below are required.

### Prerequisites

- `kubeProxyReplacement=true` is **mandatory** for Gateway API. Without it the
  operator logs `Invoke failed: failed to create gateway controller` and crashes.
- `pre-apply.sh` installs the Gateway API CRDs and applies the TLSRoute
  `v1alpha2` served patch automatically. Why the patch: v1.5.1 CRD sets
  `v1alpha2: served=false`, but the Cilium 1.19.x operator probes CRD versions
  by presence (not the served flag) and would otherwise enable TLSRoute
  support against an unserved version.

### LB-IPAM

Gateway API requires a LoadBalancer IP for each Gateway. In bare-metal/libvirt
environments, the pool is defined in
`infrastructure/network-cilium/loadbalancer-ippool.yaml`
(`CiliumLoadBalancerIPPool`, CIDR `192.168.200.0/24`) and applied by the
network-cilium kustomize apply.

Note: `start`/`stop` fields on the pool block are **ignored** by Cilium 1.19.6.

### L2 announcements for external LB access

In bare-metal environments without BGP, L2 announcements are needed for
external hosts to reach LoadBalancer IPs. This repo configures it via the
Cilium chart and kustomize resources:

1. `l2announcements.enabled: true` in
   `infrastructure/network-cilium/values.yaml` renders
   `enable-l2-announcements` in cilium-config.
2. The chart grants the leases RBAC automatically when L2 announcements are
   enabled (5 verbs, no `watch` — verified sufficient for the L2 announcer's
   leader election; the old install.sh patch that added `watch` is gone).
3. `CiliumL2AnnouncementPolicy` is a kustomize resource
   (`infrastructure/network-cilium/l2-announcement-policy.yaml`, interfaces
   `^enp`).
4. After a config change, restart agents:
   `kubectl rollout restart ds/cilium -n kube-system`.

### Host route for hypervisor access

When the LB CIDR differs from the VM network (e.g. LB on `192.168.200.0/24`,
VMs on `192.168.122.0/24`), the hypervisor cannot reach LB IPs without an
explicit route — its `virbr0` interface is on the VM subnet, so packets for
the LB subnet would otherwise go via the default gateway.

Add a direct route on the hypervisor:

```bash
# Apply immediately
sudo ip route add 192.168.200.0/24 dev virbr0

# Persist across reboots (NetworkManager)
sudo nmcli connection modify virbr0 +ipv4.routes "192.168.200.0/24"
sudo nmcli connection up virbr0
```

Other VMs on the same bridge don't need this — they ARP for LB IPs directly
via the L2 announcements above.

### Version pinning

Cilium is deployed from this repo via Kustomize (`helmCharts`); the version is
pinned in `infrastructure/network-cilium/kustomization.yaml`. Upgrade = bump
the version there (check upstream releases), run
`bash infrastructure/network-cilium/pre-apply.sh` and
`kubectl kustomize --enable-helm infrastructure/network-cilium/ |
kubectl apply -f -`, then
`kubectl rollout restart ds/cilium -n kube-system` if the configmap changed.

Do not run `cilium install`/`cilium upgrade` directly — the CLI manages the
release via Helm and conflicts with kubectl-managed (kustomize) resources.
