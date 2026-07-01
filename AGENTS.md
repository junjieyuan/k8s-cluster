# AGENTS.md

## Project nature

This repo is responsible for two things:

1. **Cluster provisioning** — VM creation, kubeadm init/join, OS config
   (see `bootstrap/`).
2. **Cluster-level infrastructure** — services that the cluster itself depends
   on to function: CNI (Cilium), CSI (NFS), GPU operator, cert-manager,
   external-dns. These live under `infrastructure/`.

**This repo does NOT manage application workloads.** User-facing services
(llama-server, web apps, etc.) belong in the **`k8s-apps`** repo
(`~/Projects/k8s-apps`). Do not place application manifests here.

**The repo must be in full sync with the cluster** — every cluster-level
resource (CNI, CSI, operators, system components) must be reflected in the
code here. No manual changes on the cluster without corresponding updates
to scripts, configs, or `.env` variables. All deploy scripts must be
idempotent — re-running them should result in no-op.

## Tool constraints

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail` on every script. Never introduce Python, Node, or other languages.
- **No package managers needed** — no `npm`, `pip`, `cargo`, etc. Runtime deps (`butane`, `envsubst`, `virsh`, `virt-install`, `kubeadm`) are system-level tools assumed pre-installed. Exception: `cilium` CLI is auto-downloaded by `infrastructure/network-cilium/install.sh` if missing.
- **Helm** is used for cluster-level operators where `values.yaml` provides clear advantage (e.g. CSI drivers). Infrastructure components like Cilium use `cilium` CLI + `helm upgrade`.

## Component versions

- **Always target latest stable** — pin explicit versions, check upstream before deployment or upgrade.
- **Source of truth** — version defaults live in each script's `usage()` or `.env.example`. This file does not duplicate them — they drift.
- **Gateway API CRDs** — install from `https://github.com/kubernetes-sigs/gateway-api/releases/download/<version>/standard-install.yaml`. Version must match what Cilium supports. Do not copy CRD YAML into the repo — always reference upstream URL.
- **Cilium** — use `cilium upgrade --version <x.y.z>` with explicit version. The CLI's built-in default may not match the latest stable.
- **Kubernetes** — `kubeadm` pins versions via `.env` or CLI flags (`--kubernetes-version`). Do not use `stable` or `latest` markers.
- **CRI-O** — version matches Kubernetes minor (e.g. k8s 1.36 → cri-o 1.36). Pinned in `.env`.

## Infrastructure best practices

- **Gateway API over Ingress** — expose services via `Gateway` + `HTTPRoute` (`gateway.networking.k8s.io/v1`). Do not use `networking.k8s.io/v1` Ingress or Cilium Ingress CRDs.
- **LB-IPAM** — always create a `CiliumLoadBalancerIPPool` for bare-metal environments. No manual external IP assignment.
- **L2 announcements** — enable in bare-metal environments for external LB access. Requires RBAC patch on `clusterrole cilium` for `leases` resource.
- **kube-proxy replacement** — mandatory for Gateway API. Cilium handles service routing via eBPF.

## Naming conventions

- **Environment variables** — use `K8S_` prefix for all `.env` variables that
  are shared across bootstrap types (e.g. `K8S_HOSTNAME`, `K8S_PREINSTALLED_PACKAGES`).
  Non-`K8S_` names are only for type-specific vars (e.g. GPU pass-through PCI addresses).
- **Version variables** — use component-specific env var names (e.g.
  `METRICS_SERVER_VERSION`, `GPU_OPERATOR_VERSION`), never bare `VERSION`.
  This avoids collisions when scripts are sourced together.
- **Helm release names** — match the directory name (e.g. `metrics-server/`
  deploys release `metrics-server`).

## Directory structure

```
bootstrap/<type>/
│   ├── .env.example           # Environment variable template
│   ├── build.sh               # Compile Butane template → Ignition config
│   ├── deploy.sh              # Type-specific deploy logic (sourced by vm-deploy.sh)
│   └── <type>.bu.tmpl         # Butane template (FCOS config)

infrastructure/<component>/
│   ├── install.sh             # Entry point (Helm upgrade --install or kubectl apply)
│   ├── values.yaml            # Helm values (only if using Helm)
│   ├── *.yaml                 # K8s resource manifests (kubectl-apply components)
│   └── secret.yaml.example    # Secret template (only if component needs credentials)

docs/                           # Upgrade guides (not daily ops — use for planned version bumps)
```

## Code style

- **Emoji** — avoid decorative emoji in scripts and templates. Use only when it genuinely aids readability of diagnostic output (e.g. `[OK]` / `[FAIL]` markers). No emoji in comments, usage texts, or echo statements that users don't need to see.
- **Comments** — keep them concise and factual. Describe *why*, not *what* the code already says. Remove stale or misleading comments immediately. In YAML templates, prefer short end-of-line annotations over multi-line block comments.
- **Runtime deps** — check with `command -v` early in the script, before any work begins. Never assume `helm`, `kubectl`, or other tools are present.

## Script invocation

All scripts use `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` to locate their resources. They can be run from any directory — `cd` is never required.

## Execution split: host vs VM

```
[host]  bootstrap/vm-image-upload.sh, bootstrap/k8s-node/build.sh,
        bootstrap/k8s-gpu-node/build.sh, bootstrap/storage-server/build.sh,
        bootstrap/vm-deploy.sh
[vm]    bootstrap/kubeadm/init-node.sh, bootstrap/kubeadm/init-control-plane.sh,
        bootstrap/kubeadm/join-worker.sh, bootstrap/kubeadm/join-control-plane.sh
[vm]    infrastructure/network-cilium/install.sh, infrastructure/storage-nfs/install.sh,
        infrastructure/gpu-operator/install.sh, infrastructure/cert-manager/install.sh,
        infrastructure/external-dns/install.sh, infrastructure/metrics-server/install.sh
```

Host scripts provision VMs; VM scripts run inside the guest. Infrastructure
scripts deploy cluster-level services (CNI, storage drivers) via kubectl/helm.
Never confuse the two.

## Privilege handling

All privileged scripts auto-escalate via `exec sudo "$0" "$@"` at the top when `$EUID -ne 0`. The caller does not need to prefix with `sudo`. Scripts that never need root:

- `bootstrap/k8s-node/build.sh` — runs butane/envsubst as normal user
- `bootstrap/k8s-gpu-node/build.sh` — runs butane/envsubst as normal user
- `bootstrap/storage-server/build.sh` — runs butane/envsubst as normal user

`infrastructure/network-cilium/install.sh` only escalates when installing the `cilium` CLI binary to `/usr/local/bin`.

The caller never needs to prefix with `sudo`. Any `sudo` in README examples refers to manual commands (e.g. `tee /etc/hosts`), not project scripts.

## Butane/Ignition flow

### K8s nodes
1. Copy `bootstrap/k8s-node/.env.example` → `bootstrap/k8s-node/.env`, fill in `K8S_PASSWORD_HASH` and `K8S_SSH_PUB_KEY` (other vars have defaults)
2. `bash bootstrap/k8s-node/build.sh` compiles `node.bu.tmpl` → `node.ign` via envsubst + butane
3. `bootstrap/vm-deploy.sh` injects `node.ign` into the VM

### GPU workers
1. Copy `bootstrap/k8s-gpu-node/.env.example` → `bootstrap/k8s-gpu-node/.env`, fill in `K8S_PASSWORD_HASH`, `K8S_SSH_PUB_KEY`, `K8S_GPU_DEVICES`, and optionally `K8S_VIRTIOFS_SOURCE`
2. `bash bootstrap/k8s-gpu-node/build.sh` compiles `gpu-worker.bu.tmpl` → `gpu-worker.ign` via envsubst + butane
3. `bootstrap/vm-deploy.sh` injects `gpu-worker.ign` into the VM
4. On first boot, uCore autorebase (unsigned → signed, 2 reboots) then k8s package install (1 reboot)
5. `deploy_finalize` stops the VM, attaches GPU PCI devices + virtiofs, sets cpu=host-passthrough + memory backing, then restarts

### Storage server
1. Copy `bootstrap/storage-server/.env.example` → `bootstrap/storage-server/.env`, fill in `K8S_PASSWORD_HASH` and `K8S_SSH_PUB_KEY` (other vars have defaults)
2. `bash bootstrap/storage-server/build.sh` compiles `storage.bu.tmpl` → `storage.ign` via envsubst + butane
3. `bootstrap/vm-deploy.sh` injects `storage.ign` into the VM

`build.sh` uses `set -a; source .env; set +a` to load all variables. `envsubst` substitutes the appropriate set of variables per template (`K8S_PASSWORD_HASH $K8S_SSH_PUB_KEY $K8S_HOSTNAME ...`).

### SELinux enforcing=0 on k8s nodes

Both `k8s-node/node.bu.tmpl` and `k8s-gpu-node/gpu-worker.bu.tmpl` set
`kernel_arguments.should_exist: [enforcing=0]` to disable SELinux enforcement.
This is a workaround for cri-o `execmem` AVC denial on kernel 7.x with composefs.
See https://bugzilla.redhat.com/show_bug.cgi?id=2477939.

Storage server templates do NOT use this — they don't run cri-o or kubelet so
the denial doesn't apply.

## kubeadm configs are templates

`kubeadm-init.yaml`, `kubeadm-join-worker.yaml`, `kubeadm-join-control-plane.yaml` contain `${VARIABLE}` placeholders. They are NOT directly usable — scripts like `init-control-plane.sh` pipe them through `envsubst` into temp files (cleaned up via `trap`).

## Hardcoded that shouldn't be changed

- `unix:///var/run/crio/crio.sock` — CRI-O standard socket
- `/etc/kubernetes/admin.conf` — kubeadm standard path
- Kernel modules (`overlay`, `br_netfilter`) and sysctl params — k8s requirements

## Hardcoded that IS configurable

- `control-plane.k8s.junjie.pro:6443` — default, override with `--endpoint`
- `172.16.0.0/12` / `10.96.0.0/12` — pod/service CIDRs, override with `--pod-cidr` / `--cidr`
- Package versions via `.env` vars or CLI flags
- `K8S_PREINSTALLED_PACKAGES` — rpm-ostree packages, set in `.env`
- `K8S_HOSTNAME` — OS hostname set by Ignition, set in `.env`
- `K8S_CPUS`, `K8S_MEMORY`, `K8S_DISK_SIZE` — VM hardware sizing, set in `.env`, override with `--cpus`/`--memory`/`--disk-size`
- `--no-blockpull` — skip backing file pull after `virt-install` (faster provisioning)
- `--install-cni` / `--cni-version` — auto-install Cilium after `kubeadm init`
- `--dry-run` — available on most scripts, print generated config and commands
- Infrastructure `install.sh` scripts accept `--version` to override chart/image version

## Secrets

**Separate secrets from code.** Real values live in gitignored files
(`.env`, `*.ign`, credentials). Committed files use `.example` variants
with placeholder values only. This keeps secrets out of git history and
allows each environment to supply its own values.

**Absolute prohibition:** never commit any secret, key, password, token,
certificate, or credential to this repository. This includes but is not
limited to SSH private keys, API keys, kubeconfig files, password hashes
(except in `.env.example` placeholders), and TLS certificates.

## Cilium Gateway API — known issues

Cilium Gateway API requires several manual steps beyond `cilium upgrade --set gatewayAPI.enabled=true`. These are handled by the install script for fresh installs, but must be done manually when enabling Gateway API on an existing cluster.

### Prerequisites

- `kubeProxyReplacement=true` is **mandatory** for Gateway API. Without it the operator logs `Invoke failed: failed to create gateway controller` and crashes.
- Gateway API CRDs **must** be installed before the Cilium upgrade:
  ```bash
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
  ```
- **TLSRoute `v1alpha2` patch**: v1.5.1 CRD sets `v1alpha2: served=false`, but Cilium 1.19.x operator requires it. After installing CRDs:
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

#### L2 announcements for external LB access

In bare-metal environments without BGP, L2 announcements are needed for
external hosts to reach LoadBalancer IPs. This requires:

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

`cilium upgrade` without `--version` uses the CLI's **built-in default**, not the
currently running version or latest stable. Check with `cilium version` first.

```bash
# Shows: cilium image (default): v1.19.3, cilium image (stable): v1.19.4
cilium version
# Always specify --version to avoid accidental downgrade
cilium upgrade --version 1.19.4 --set gatewayAPI.enabled=true --set kubeProxyReplacement=true
```

## cert-manager — DNS-01 with Cloudflare

ClusterIssuer `letsencrypt-prod` uses DNS-01 challenge with a Cloudflare API
token to support wildcard certificates (`*.k8s.junjie.pro`). The token lives
in a manually-created Secret:

```bash
kubectl create secret generic cloudflare-api-token \
    --from-literal=api-token=<token> -n cert-manager
```

The `infrastructure/cert-manager/install.sh` creates the ClusterIssuer
referencing this Secret. HTTP-01 challenges are insufficient for wildcard
certificates — DNS-01 is mandatory.

## Debugging deployments

- **After deploying any new component, immediately check logs** for E/F-level
  errors: `kubectl logs -n <namespace> deployment/<name>`. CrashLoop/BackOff
  must be investigated before moving on.
- **Always use the install script to deploy** — never `kubectl apply -f` directly
  on YAML files that contain `${VAR}` placeholders. The scripts handle
  `envsubst` substitution via temporary files. Direct apply will pass literals
  like `${API_SERVER_ADVERTISE_ADDRESS}` to the component, causing silent
  misconfiguration.
- **Verify RBAC against upstream docs** — controllers like external-dns often
  require `get/list/watch` on `namespaces` in addition to their primary
  resources. Missing permissions cause crash loops with `forbidden` errors.
  Check the component's official RBAC manifest, don't guess.

## Deployment checklist

Before declaring any infrastructure component "done", verify every item.
This applies to new components and upgrades alike.

### Version consistency

- [ ] `usage()` help text, script default variable, Helm chart version, and
  container image tag all reference the same version.
- [ ] Version is overridable via both `--version` CLI flag and an environment
  variable (e.g. `METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-3.13.1}"`).
  Use component-specific env var names to avoid collisions.
- [ ] `helm search repo <chart> --versions` confirms this is the latest stable.

### values.yaml

- [ ] Contains **only** values that differ from the chart defaults. Run
  `helm show values <chart> --version <x.y.z>` to check each key.
- [ ] Every non-default value has a comment explaining **why** it's set
  (not what it does — the upstream docs already say that).
- [ ] Prefer `args` (append) over overriding `defaultArgs` (replace) so chart
  defaults pass through transparently.

### Helm upgrade command

- [ ] Always uses `--wait --timeout 5m`. Without it, the script exits before
  pods are ready and hides startup failures.
- [ ] `--dry-run` output is an exact copy of the real command, including all
  flags, quotes, and variable references. No prose summaries — the user must
  be able to copy-paste the dry-run output and run it manually.

### Idempotency

- [ ] Re-running `install.sh` produces a no-op: `helm upgrade --install`
  reports no changes, no pods restart.

### Post-deploy verification

- [ ] `kubectl logs -n <ns> deployment/<name>` shows no E/F-level errors.
- [ ] Pod status is `Running` with all containers `Ready`.
- [ ] The script's final summary echoes the version that was actually deployed.
- [ ] `kubectl top nodes` / `kubectl top pods -A` works if metrics-server was
  part of the change.

### Helm release sync

- [ ] `helm -n <ns> get values <release> -a` (computed values) matches the
  intent of the local `values.yaml`. No stale keys from previous revisions.
- [ ] `kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].image}'`
  matches the chart's app version.

### Script conventions

- [ ] `SCRIPT_DIR` pattern used for locating sibling files.
- [ ] Helm repo detection uses structured output:
  `helm repo list -o yaml 2>/dev/null | grep -q "<repo-url>"` — never parse
  the human-readable table with `grep '^name\b'`.
- [ ] `helm repo update <name>` runs after `helm repo add`, not only in the
  already-exists branch.
- [ ] Clustered changes (e.g. Cilium operator restart after config patch) use
  `kubectl rollout restart` and wait for availability.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- No `chore:` or `style:` — keep it semantic
- Each commit changes one logical concern

## Image provisioning order

1. `bootstrap/vm-image-upload.sh` → libvirt storage pool
2. `bootstrap/<type>/build.sh` → Ignition config (node.ign / gpu-worker.ign / storage.ign)
3. `bootstrap/vm-deploy.sh --type <type>` → VM

After provisioning, `vm-deploy.sh` removes the fwcfg Ignition from the domain XML
(security — the Ignition config contains the password hash) and enables autostart.
For GPU nodes, `deploy_finalize` additionally attaches PCI devices, virtiofs, and
configures CPU/memory backing.
