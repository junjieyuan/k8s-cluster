# Deployment checklist

Before declaring any infrastructure component "done", verify every item.
This applies to new components and upgrades alike.

---

## Version consistency

- [ ] Version is declared in `kustomization.yaml`:
  - `helmCharts` components: `helmCharts[].version` field
  - Plain YAML components: `images.newTag` field
- [ ] `helm search repo <chart> --versions` (or upstream release page)
  confirms this is the latest stable.

## values.yaml

- [ ] Contains **only** values that differ from the chart defaults. Run
  `helm show values <chart> --version <x.y.z>` to check each key.
- [ ] Every non-default value has a comment explaining **why** it's set
  (not what it does — the upstream docs already say that).
- [ ] Prefer `args` (append) over overriding `defaultArgs` (replace) so chart
  defaults pass through transparently.

## Kustomize build

- [ ] `kubectl kustomize --enable-helm <dir>/` succeeds without errors.
- [ ] `kubectl diff -f -` shows only expected changes (new hook resources,
  secret regeneration). No unexpected deletions or spec changes on existing
  resources.

## Idempotency

- [ ] Re-running the deploy command produces a no-op: no pods restart,
  no resources created or changed.
  `kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -`
  shows only annotation patches on existing resources.

## Post-deploy verification

- [ ] `kubectl logs -n <ns> deployment/<name>` shows no E/F-level errors.
- [ ] Pod status is `Running` with all containers `Ready`.
- [ ] `kubectl top nodes` / `kubectl top pods -A` works if metrics-server was
  part of the change.

## Secret management

- [ ] `.env` exists with real values (gitignored).
- [ ] `.env.example` committed with placeholder values as template.
- [ ] `secretGenerator` in `kustomization.yaml` references the correct `.env` keys.
- [ ] For CRD-level secret references (e.g. `apiTokenSecretRef.name`),
  `generatorOptions.disableNameSuffixHash: true` is set since kustomize
  cannot auto-rewrite custom resource fields.

## Cilium

- [ ] `pre-apply.sh` run before the first deploy (Gateway API CRDs from the
  upstream release URL).
- [ ] Chart rendered with `kubectl kustomize --enable-helm
  infrastructure/network-cilium/`; version pinned in `kustomization.yaml`.
- [ ] `kubectl diff` against live shows no unexpected spec changes.
- [ ] Clustered changes (e.g. operator restart after config patch) use
  `kubectl rollout restart` and wait for availability.
- [ ] Gateway API CRD version matches what Cilium supports.
