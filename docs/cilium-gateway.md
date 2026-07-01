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

The install script is `infrastructure/network-cilium/install.sh`. It handles
fresh installs. When enabling Gateway API on an existing cluster, the manual
steps below are required.

### Prerequisites

- `kubeProxyReplacement=true` is **mandatory** for Gateway API. Without it the
  operator logs `Invoke failed: failed to create gateway controller` and crashes.
- Gateway API CRDs **must** be installed before the Cilium upgrade:
  ```bash
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
  ```
- **TLSRoute `v1alpha2` patch**: v1.5.1 CRD sets `v1alpha2: served=false`, but
  Cilium 1.19.x operator requires it. After installing CRDs:
  ```bash
  kubectl patch crd tlsroutes.gateway.networking.k8s.io --type=json \
    -p='[{"op": "replace", "path": "/spec/versions/1/served", "value": true}]'
  ```

### LB-IPAM

Gateway API requires a LoadBalancer IP for each Gateway. In bare-metal/libvirt
environments, create a `CiliumLoadBalancerIPPool`:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: default
spec:
  blocks:
    - cidr: 192.168.122.0/24
EOF
```

Note: `start`/`stop` fields on the pool block are **ignored** by Cilium 1.19.4.

### L2 announcements for external LB access

In bare-metal environments without BGP, L2 announcements are needed for
external hosts to reach LoadBalancer IPs:

1. Enable in Cilium config:
   ```bash
   kubectl patch configmap cilium-config -n kube-system --type=json \
     -p='[{"op": "add", "path": "/data/enable-l2-announcements", "value": "true"}]'
   ```
2. Add leases RBAC (`cilium upgrade` does not add it):
   ```bash
   kubectl patch clusterrole cilium --type=json -p='[
     {"op": "add", "path": "/rules/-", "value": {"apiGroups": ["coordination.k8s.io"], "resources": ["leases"], "verbs": ["get","list","watch","create","update","delete"]}}
   ]'
   ```
3. Create `CiliumL2AnnouncementPolicy` with the node interfaces (e.g. `^enp`).
4. Restart Cilium agents.

### cilium CLI version caveat

`cilium upgrade` without `--version` uses the CLI's **built-in default**, not
the currently running version or latest stable. Check with `cilium version` first:

```bash
# Shows: cilium image (default): v1.19.3, cilium image (stable): v1.19.4
cilium version
# Always specify --version to avoid accidental downgrade
cilium upgrade --version 1.19.4 --set gatewayAPI.enabled=true --set kubeProxyReplacement=true
```
