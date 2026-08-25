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
- [ ] Rendered images match their pinned references —
  `kubectl kustomize --enable-helm <dir>/ | grep image:`. A rendered image
  without tag/digest means the pin didn't match (silent failure) — check the
  `images[].name` entry (plain YAML) or values key (helmCharts) against the
  deployment's image.

## KYAML formatting

- [ ] Every `*.yaml` in the change is KYAML-formatted; `yamlfmt -lint <dir>/`
  passes (or `yamlfmt -dry` shows no diff).

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
  no resources created or changed. The check is an empty diff, not the
  `apply` verb (apply reports `configured` even when nothing changed):
  `kubectl kustomize --enable-helm <dir>/ | kubectl diff -f -` shows no
  output.

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
  infrastructure/cilium/`; version pinned in `kustomization.yaml`.
- [ ] `kubectl diff` against live shows no unexpected spec changes.
- [ ] Clustered changes (e.g. operator restart after config patch) use
  `kubectl rollout restart` and wait for availability.
- [ ] Gateway API CRD version matches what Cilium supports.

## Committed

- [ ] The change is committed (see Commit conventions in `AGENTS.md`); an
  uncommitted change leaves the repo out of sync with the cluster.
