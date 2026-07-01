# Deployment checklist

Before declaring any infrastructure component "done", verify every item.
This applies to new components and upgrades alike.

---

## Version consistency

- [ ] `usage()` help text, script default variable, Helm chart version, and
  container image tag all reference the same version.
- [ ] Version is overridable via both `--version` CLI flag and an environment
  variable (e.g. `METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-3.13.1}"`).
  Use component-specific env var names to avoid collisions.
- [ ] `helm search repo <chart> --versions` confirms this is the latest stable.

## values.yaml

- [ ] Contains **only** values that differ from the chart defaults. Run
  `helm show values <chart> --version <x.y.z>` to check each key.
- [ ] Every non-default value has a comment explaining **why** it's set
  (not what it does — the upstream docs already say that).
- [ ] Prefer `args` (append) over overriding `defaultArgs` (replace) so chart
  defaults pass through transparently.

## Helm upgrade command

- [ ] Always uses `--wait --timeout 5m`. Without it, the script exits before
  pods are ready and hides startup failures.
- [ ] `--dry-run` output is an exact copy of the real command, including all
  flags, quotes, and variable references. No prose summaries — the user must
  be able to copy-paste the dry-run output and run it manually.

## Idempotency

- [ ] Re-running `install.sh` produces a no-op: `helm upgrade --install`
  reports no changes, no pods restart.

## Post-deploy verification

- [ ] `kubectl logs -n <ns> deployment/<name>` shows no E/F-level errors.
- [ ] Pod status is `Running` with all containers `Ready`.
- [ ] The script's final summary echoes the version that was actually deployed.
- [ ] `kubectl top nodes` / `kubectl top pods -A` works if metrics-server was
  part of the change.

## Helm release sync

- [ ] `helm -n <ns> get values <release> -a` (computed values) matches the
  intent of the local `values.yaml`. No stale keys from previous revisions.
- [ ] `kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].image}'`
  matches the chart's app version.

## Script conventions

- [ ] `SCRIPT_DIR` pattern used for locating sibling files.
- [ ] Helm repo detection uses structured output:
  `helm repo list -o yaml 2>/dev/null | grep -q "<repo-url>"` — never parse
  the human-readable table with `grep '^name\b'`.
- [ ] `helm repo update <name>` runs after `helm repo add`, not only in the
  already-exists branch.
- [ ] Clustered changes (e.g. Cilium operator restart after config patch) use
  `kubectl rollout restart` and wait for availability.
