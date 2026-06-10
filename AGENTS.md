# AGENTS.md

## Project nature

This is a k8s cluster provisioning project — Bash scripts and YAML templates, not a software application. There are no build commands, tests, linters, or type checkers.

## Tool constraints

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail` on every script. Never introduce Python, Node, or other languages.
- **No package managers needed** — no `npm`, `pip`, `cargo`, etc. Runtime deps (`butane`, `envsubst`, `virsh`, `virt-install`, `kubeadm`) are system-level tools assumed pre-installed. Exception: `cilium` CLI is auto-downloaded by `infrastructure/network-cilium/install.sh` if missing.

## Code style

- **Emoji** — avoid decorative emoji in scripts and templates. Use only when it genuinely aids readability of diagnostic output (e.g. `[OK]` / `[FAIL]` markers). No emoji in comments, usage texts, or echo statements that users don't need to see.
- **Comments** — keep them concise and factual. Describe *why*, not *what* the code already says. Remove stale or misleading comments immediately. In YAML templates, prefer short end-of-line annotations over multi-line block comments.

## Script invocation

All scripts use `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` to locate their resources. They can be run from any directory — `cd` is never required.

## Execution split: host vs VM

```
[host]  bootstrap/vm-image-upload.sh, bootstrap/k8s-node/build.sh,
        bootstrap/storage-server/build.sh, bootstrap/vm-deploy.sh
[vm]    bootstrap/kubeadm/init-node.sh, bootstrap/kubeadm/init-control-plane.sh,
        bootstrap/kubeadm/join-worker.sh, bootstrap/kubeadm/join-control-plane.sh
[vm]    infrastructure/network-cilium/install.sh, infrastructure/storage-nfs/install.sh
```

Host scripts provision VMs; VM scripts run inside the guest. Infrastructure
scripts deploy cluster-level services (CNI, storage drivers) via kubectl/helm.
Never confuse the two.

## Privilege handling

All privileged scripts auto-escalate via `exec sudo "$0" "$@"` at the top when `$EUID -ne 0`. The caller does not need to prefix with `sudo`. Scripts that never need root:

- `bootstrap/k8s-node/build.sh` — runs butane/envsubst as normal user
- `bootstrap/storage-server/build.sh` — runs butane/envsubst as normal user

`infrastructure/network-cilium/install.sh` only escalates when installing the `cilium` CLI binary to `/usr/local/bin`.

The caller never needs to prefix with `sudo`. Any `sudo` in README examples refers to manual commands (e.g. `tee /etc/hosts`), not project scripts.

## Butane/Ignition flow

### K8s nodes
1. Copy `bootstrap/k8s-node/.env.example` → `bootstrap/k8s-node/.env`, fill in `K8S_PASSWORD_HASH` and `K8S_SSH_PUB_KEY` (other vars have defaults)
2. `bash bootstrap/k8s-node/build.sh` compiles `node.bu.tmpl` → `node.ign` via envsubst + butane
3. `bootstrap/vm-deploy.sh` injects `node.ign` into the VM

### Storage server
1. Copy `bootstrap/storage-server/.env.example` → `bootstrap/storage-server/.env`, fill in `K8S_PASSWORD_HASH` and `K8S_SSH_PUB_KEY` (other vars have defaults)
2. `bash bootstrap/storage-server/build.sh` compiles `storage.bu.tmpl` → `storage.ign` via envsubst + butane
3. `bootstrap/vm-deploy.sh` injects `storage.ign` into the VM

`build.sh` uses `set -a; source .env; set +a` to load all variables. `envsubst` substitutes the appropriate set of variables per template (`K8S_PASSWORD_HASH $K8S_SSH_PUB_KEY $K8S_HOSTNAME ...`).

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

## Secrets

`.env` and `*.ign` are gitignored. `.env.example` uses placeholder values only. Real credentials were never committed. Never add real secrets to templates or example files.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- No `chore:` or `style:` — keep it semantic
- Each commit changes one logical concern

## Image provisioning order

1. `bootstrap/vm-image-upload.sh` → libvirt storage pool
2. `bootstrap/k8s-node/build.sh` → `node.ign` (or `bootstrap/storage-server/build.sh` → `storage.ign`)
3. `bootstrap/vm-deploy.sh` → VM

After provisioning, `vm-deploy.sh` removes fwcfg Ignition from the domain XML (security) and enables autostart.
