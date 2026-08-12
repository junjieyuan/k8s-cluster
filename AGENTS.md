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
resource must be reflected in code here. No manual changes on the cluster
without corresponding updates to manifests or configs. All deployments must
be idempotent — re-running them should result in no-op.

## Tool constraints

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail` on every script.
  Never introduce Python, Node, or other languages.
- **No package managers** — no `npm`, `pip`, `cargo`, etc. Runtime deps
  (`butane`, `envsubst`, `virsh`, `virt-install`, `kubeadm`) are system-level
  tools assumed pre-installed. Exception: `cilium` CLI is auto-downloaded by
  `infrastructure/network-cilium/install.sh` if missing.
- **Helm** is used **only** via the Kustomize `helmCharts` generator
  (`kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -`), never
  `helm install` directly. Exception: Cilium uses `cilium` CLI for its
  complex multi-step setup (CRD patching, L2 announcement config).

## YAML is KYAML

Every `*.yaml` in this repo is written in **KYAML**, the flow-style YAML
dialect from KEP 5295: `---` document headers, `{}` maps, `[]` lists,
double-quoted strings, trailing commas. KYAML is valid YAML, so `kubectl`,
Kustomize, and Helm consume it unchanged. Format with Google's `yamlfmt`
using the repo-root `.yamlfmt` config (`formatter.type: kyaml`):

```bash
yamlfmt -dry <file>   # preview without modifying
yamlfmt <file>        # format in place
yamlfmt -lint <dir>/  # enforce
```

- **No redundant defaults** — omit fields that match Kubernetes or the
  pinned chart version's defaults (e.g. `volumeBindingMode: Immediate`,
  chart default `logLevel`), and keep only intentional overrides. Verify
  chart defaults against the cached chart (`infrastructure/*/charts/`)
  before dropping a value.
- **Comments explain why, not what** — the manifest itself is the what; a
  comment should capture the decision or constraint that isn't visible in
  the YAML (e.g. why `reclaimPolicy: Retain`, why a pinned size).
- **Validate chart value keys** — misspelled or wrongly nested values are
  silently ignored by Helm. Check keys against the pinned chart version
  (cached under `infrastructure/*/charts/`) before changing values files.
- **Not YAML** — `.env*` files are dotenv input for Kustomize
  `secretGenerator`, `*.ign` are generated Ignition configs, and vendored
  Helm chart sources under gitignored `charts/` are third-party; none are
  reformatted.

Exception: kubeadm configs under `bootstrap/kubeadm/` are KYAML-formatted
but keep their `${VARIABLE}` placeholders — they are envsubst sources, and
KYAML's double-quoted strings preserve substitution.

## Component versions

- **Always target latest stable** — pin explicit versions, check upstream
  before deployment or upgrade.
- **Source of truth** — version defaults live in each script's `usage()`,
  `.env.example`, or `kustomization.yaml` (infrastructure components).
  This file does not duplicate them — they drift.
- **Kubernetes** — `kubeadm` pins versions via `.env` or `--kubernetes-version`.
  **CRI-O** — version matches Kubernetes minor. Never use `stable`/`latest` markers.
- **升级顺序** — rpm-ostree 更新 kubelet/kubeadm 后，**必须**在 control-plane 节点上运行
  `sudo kubeadm upgrade plan` 查看可升级版本，确认后运行
  `sudo kubeadm upgrade apply <version>` 升级控制面静态 pod
  （apiserver/controller-manager/scheduler），否则 kubelet 与控制面版本会不一致。
- **Gateway API CRDs** — install from upstream release URL; version must match
  what Cilium supports. Do not copy CRD YAML into the repo.

## Infrastructure best practices

See `docs/cilium-gateway.md` for detailed setup and known issues.

- **Gateway API over Ingress** — use `Gateway` + `HTTPRoute`, never Ingress or
  Cilium Ingress CRDs.
- **LB-IPAM** — always create a `CiliumLoadBalancerIPPool` for bare-metal.
- **L2 announcements** — enable in bare-metal environments (needs `leases` RBAC).
- **kube-proxy replacement** — mandatory for Gateway API.

## Naming conventions

- **Environment variables** — use `K8S_` prefix for all `.env` variables that
  are shared across bootstrap types. Non-`K8S_` names only for type-specific
  vars (e.g. GPU pass-through PCI addresses).
- **Helm release names** — match the directory name.

## Directory structure

```
bootstrap/<type>/
│   ├── .env.example           # Environment variable template
│   ├── <type>.bu.tmpl         # Butane template (FCOS config)
│   └── deploy.sh              # Optional type-specific overrides (e.g. GPU)
├── build-ignition.sh            # Shared: compile .bu.tmpl → .ign (all types)
├── vm-deploy.sh                 # VM provisioning orchestrator (auto-discovers types)
├── vm-image-upload.sh           # Upload FCOS image to libvirt
└── kubeadm/                     # kubeadm init/join scripts and templates

infrastructure/<component>/
│   ├── kustomization.yaml      # helmCharts (preferred) or resources + secretGenerator
│   ├── values.yaml             # Helm chart values (helmCharts components)
│   ├── namespace.yaml          # Namespace definition (unless using kube-system)
│   ├── *.yaml                  # K8s resource manifests (no ${VAR} placeholders)
│   └── .env.example            # Secret template (components needing credentials)

docs/                           # Detailed reference: upgrade guides, known issues,
│                               # checklists, component setup notes
```

## Shell scripts (bootstrap + cilium)

Bootstrap and `infrastructure/network-cilium/install.sh` are the only shell
scripts in this repo. Infrastructure components use `kubectl kustomize`.

- `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` to locate
  sibling resources. All scripts can be run from any directory.
- **Runtime deps** — check with `command -v` early in the script, before any
  work begins.
- **Emoji** — avoid decorative emoji. Use only when it genuinely aids
  readability of diagnostic output (e.g. `[OK]` / `[FAIL]` markers).
- **Comments** — concise and factual. Describe *why*, not *what*.
- **Privilege** — scripts that need root auto-escalate via
  `exec sudo "$0" "$@"` when `$EUID -ne 0`. Exceptions:
  `bootstrap/build-ignition.sh` (butane/envsubst as normal user);
  `infrastructure/network-cilium/install.sh` only escalates when installing
  the `cilium` CLI binary.

## Execution split: host vs VM

```
[host]  bootstrap/vm-image-upload.sh, bootstrap/build-ignition.sh,
        bootstrap/vm-deploy.sh (discovers types under bootstrap/)
[vm]    bootstrap/kubeadm/init-node.sh, bootstrap/kubeadm/init-control-plane.sh,
        bootstrap/kubeadm/join-worker.sh, bootstrap/kubeadm/join-control-plane.sh
[vm]    infrastructure/network-cilium/install.sh  (cilium CLI — complex setup)
[vm]    infrastructure/*/ (all other components — kubectl kustomize --enable-helm)
```

Host scripts provision VMs; VM scripts run inside the guest. Infrastructure
is deployed via kustomize from the control-plane node.

## Infrastructure deployment

All infrastructure components except Cilium use Kustomize.
No `helm install` directly — Helm charts are declared in `kustomization.yaml`.

```bash
# All helmCharts components (all use --enable-helm)
kubectl kustomize --enable-helm infrastructure/cert-manager/ | kubectl apply -f -
kubectl kustomize --enable-helm infrastructure/external-dns/ | kubectl apply -f -
kubectl kustomize --enable-helm infrastructure/gpu-operator/ | kubectl apply -f -
kubectl kustomize --enable-helm infrastructure/metrics-server/ | kubectl apply -f -
kubectl kustomize --enable-helm infrastructure/storage-nfs/ | kubectl apply -f -
```

Secrets use `secretGenerator` with `.env` files (real values gitignored,
`.env.example` committed as template). For CRD custom fields that reference
secret names (e.g. `apiTokenSecretRef.name`), use
`generatorOptions.disableNameSuffixHash: true` since kustomize cannot
auto-rewrite CRD-level secret references.

Version pinning:
- `helmCharts`: `helmCharts[].version` in `kustomization.yaml`
- Plain YAML: `images.newTag` in `kustomization.yaml`

## Butane/Ignition flow

All types follow the same pattern:
1. Copy `.env.example` → `.env`, fill in required variables.
2. `build-ignition.sh` compiles the `.bu.tmpl` via envsubst + butane → `.ign`.
3. `vm-deploy.sh` injects the Ignition config into the VM.
4. `vm-deploy.sh` removes fwcfg Ignition from domain XML after provisioning
   (security — the Ignition config contains the password hash).

`build-ignition.sh` uses `set -a; source .env; set +a` to load variables. `envsubst`
substitutes only the variables the template needs — not everything in `.env`.

**GPU workers** additionally: uCore autorebase (2 reboots), k8s package
install (1 reboot). GPU PCI devices, virtiofs, `cpu=host-passthrough`, and
`memoryBacking` are configured in the domain XML before first boot via
`deploy_prepare_domain_xml` — no post-boot reconfiguration needed.

### SELinux enforcing=0 on k8s nodes

Both `k8s-node/node.bu.tmpl` and `k8s-gpu-node/gpu-worker.bu.tmpl` set
`kernel_arguments.should_exist: [enforcing=0]` to disable SELinux enforcement.
This is a workaround for cri-o `execmem` AVC denial on kernel 7.x with
composefs. See https://bugzilla.redhat.com/show_bug.cgi?id=2477939.

Storage server templates do NOT use this — they don't run cri-o or kubelet.

## kubeadm configs are templates

`kubeadm-init.yaml`, `kubeadm-join-worker.yaml`, `kubeadm-join-control-plane.yaml`
contain `${VARIABLE}` placeholders. They are NOT directly usable — scripts
pipe them through `envsubst` into temp files (cleaned up via `trap`). They are
KYAML-formatted (see "YAML is KYAML") — re-run `yamlfmt` after editing.

## Hardcoded that shouldn't be changed

- `unix:///var/run/crio/crio.sock` — CRI-O standard socket
- `/etc/kubernetes/admin.conf` — kubeadm standard path
- Kernel modules (`overlay`, `br_netfilter`) and sysctl params — k8s requirements

## Hardcoded that IS configurable

- `control-plane.k8s.junjie.pro:6443` — override with `--endpoint`
- `172.16.0.0/12` / `10.96.0.0/12` — override with `--pod-cidr` / `--cidr`
- Package versions via `.env` vars or CLI flags
- `K8S_PREINSTALLED_PACKAGES`, `K8S_HOSTNAME` — set in `.env`
- `K8S_CPUS`, `K8S_MEMORY`, `K8S_DISK_SIZE` — set in `.env`, override with
  `--cpus`/`--memory`/`--disk-size`
- `--no-blockpull` — skip backing file pull after `virt-install`
- `--install-cni` / `--cni-version` — auto-install Cilium after `kubeadm init`
- `--dry-run` — available on most scripts
- Infrastructure components pin versions in `kustomization.yaml`
  (`helmCharts[].version` or `images.newTag`)

## Secrets

**Separate secrets from code.** Real values live in gitignored files
(`.env`, `*.ign`, credentials). Committed files use `.example` variants
with placeholder values only.

**Absolute prohibition:** never commit any secret, key, password, token,
certificate, or credential to this repository. This includes SSH private keys,
API keys, kubeconfig files, password hashes (except in `.env.example`
placeholders), and TLS certificates.

## Debugging deployments

- **Check logs immediately** after deploying any component:
  `kubectl logs -n <ns> deployment/<name>`. Investigate CrashLoop/BackOff
  before moving on.
- **Always use kustomize for infrastructure** — `kubectl apply -k` or
  `kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -`. Never
  `kubectl apply -f` directly on infrastructure YAML files.
  Bootstrap kubeadm configs contain `${VAR}` placeholders; those are
  piped through `envsubst` by their scripts.
- **Verify RBAC against upstream docs** — controllers like external-dns often
  need `get/list/watch` on `namespaces` beyond their primary resources.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`
- Each commit changes one logical concern

## Image provisioning order

1. `bootstrap/vm-image-upload.sh` → libvirt storage pool
2. `bootstrap/<type>/build.sh` → Ignition config
3. `bootstrap/vm-deploy.sh --type <type>` → VM

After provisioning, `vm-deploy.sh` removes the fwcfg Ignition from the domain
XML and enables autostart. For GPU nodes, `deploy_prepare_domain_xml` attaches
PCI devices, virtiofs, and configures CPU/memory backing in the domain XML
before first boot.

## Reference docs

- `docs/cilium-gateway.md` — Gateway API setup, LB-IPAM, L2 announcements, known issues
- `docs/deployment-checklist.md` — pre-deploy verification checklist
- `docs/control-plane-upgrade.md` — control-plane node upgrade procedure
- `docs/worker-upgrade.md` — worker node upgrade procedure
- `docs/gpu-worker-upgrade.md` — GPU worker node upgrade procedure
