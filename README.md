# kubequest

This repository contains:

- the application code
- GitHub Actions CI/CD workflows
- Helm charts
- Argo CD application definitions
- Kubernetes/GitOps deployment resources

This document describes the **current workflow implemented in the repository**.

## Repository structure

- `services/sample-app-master/`
  - Laravel/PHP application source code
- `.github/workflows/`
  - CI/CD workflows
- `gitops/charts/sample-app/`
  - Helm chart for the sample app
- `gitops/argocd/`
  - Argo CD `Application` resources
- `gitops/secrets/`
  - sealed secrets used by Argo CD

## Current deployment model

There are two Argo CD applications:

- `sample-app-dev`
  - defined in `gitops/argocd/sample-app-dev.yaml`
  - tracks the **`dev` branch**
  - renders:
    - `values.yaml`
    - `values-dev.yaml`
  - deploys to namespace `sample-app-dev`

- `sample-app-prod`
  - defined in `gitops/argocd/sample-app-prod.yaml`
  - tracks the **`main` branch**
  - renders:
    - `values.yaml`
    - `values-prod.yaml`
  - deploys to namespace `sample-app-prod`

Argo CD is Git-driven:

- when Git changes in the tracked branch
- Argo re-renders the Helm chart
- Argo compares desired state to the cluster
- Argo applies the diff automatically

## Version ownership

Runtime application versioning is **environment-specific**.

The deployed app version is **not driven by `Chart.yaml appVersion`**.

Instead:

- `values-dev.yaml` owns:
  - `image.tag`
  - `migration.releaseId`
- `values-prod.yaml` owns:
  - `image.tag`
  - `migration.releaseId`

`Chart.yaml` still exists because Helm requires chart metadata, but it is **not the source of truth for deployed app versions**.

## Helm chart behavior

The sample app chart lives in:

- `gitops/charts/sample-app/`

### Runtime image version

The application deployment uses:

- `.Values.image.repository`
- `.Values.image.tag`

### Migration job

The chart includes a Kubernetes `Job` used for migrations.

It is versioned by:

- `.Values.migration.releaseId`

This is used to make the Job name change when a new release is deployed.

### Sync order in Argo CD

The chart uses sync waves:

- wave `0`
  - MySQL resources
- wave `1`
  - migration job
- wave `2`
  - application service and deployment

This ensures:

1. database comes first
2. migrations run next
3. application rollout happens after that

### Seeds

Automatic seeding is **disabled** from the rollout path.

The migration job only runs:

```bash
php artisan migrate --force
```

If seeding is needed, it is a **manual operation**.

The application README documents the command:

```bash
kubectl exec -n sample-app-prod deploy/sample-app -- php artisan db:seed --force
```

## Dev CI/CD workflow

The active automated workflow for the sample app is:

- `.github/workflows/sample-app-master-ci.yml`

This workflow currently applies to the **`dev` branch flow**.

### Trigger

It runs when a **pull request into `dev` is closed and merged**, and only if the PR touched:

- `services/sample-app-master/**`
- or `.github/workflows/sample-app-master-ci.yml`

### Validation workflow before merge

There is also a release-intent validation workflow:

- `.github/workflows/sample-app-release-prep.yml`

This runs on PR activity targeting `dev`.

It allows:

- **no release label**
  - normal dev merge
- **exactly one release label** among:
  - `VERSION-MAJOR`
  - `VERSION-MINOR`
  - `VERSION-HOT`

It rejects:

- more than one release label at the same time

## Dev merge behavior

When a PR is merged into `dev`, the workflow runs tests first, then executes one of two release modes.

### Case 1 - merged PR into `dev` with **no** `VERSION-*` label

This is treated as a normal dev integration.

Flow:

1. CI reads the current core version from `values-dev.yaml`
2. CI computes a dev version:

   - `<core-version>-dev.<merge-sha-12>`

   Example:

   - `0.1.0-dev.a1b2c3d4e5f6`

3. CI runs tests
4. CI builds the Docker image
5. CI pushes the image to:

   - `registry.kwer.fr/kubequest/dev/sample-app-master`

6. CI updates `gitops/charts/sample-app/values-dev.yaml`:

   - `image.tag`
   - `migration.releaseId`

7. CI commits the updated `values-dev.yaml` back to `dev`
8. Argo CD sees the Git change on `dev`
9. Argo CD deploys the new version to `sample-app-dev`

### Case 2 - merged PR into `dev` with a `VERSION-*` label

This is treated as a dev release cut.

Supported labels:

- `VERSION-MAJOR`
- `VERSION-MINOR`
- `VERSION-HOT`

Flow:

1. CI reads the previous stable Git tags matching:

   - `vX.Y.Z`

2. CI computes the next stable version:

   - `VERSION-MAJOR` → `+1.0.0`
   - `VERSION-MINOR` → `+0.1.0`
   - `VERSION-HOT` → `+0.0.1`

3. CI creates and pushes the new Git tag

   Example:

   - `v0.2.0`

4. CI runs tests
5. CI builds the Docker image
6. CI pushes the image to:

   - `registry.kwer.fr/kubequest/dev/sample-app-master:<new-version>`

7. CI updates `gitops/charts/sample-app/values-dev.yaml`:

   - `image.tag = <new-version>`
   - `migration.releaseId = <new-version>`

8. CI commits the updated `values-dev.yaml` back to `dev`
9. Argo CD sees the Git change on `dev`
10. Argo CD deploys the released version to `sample-app-dev`

## What the workflow tests

Before image build/push, CI runs:

- Composer validation
- PHP dependency install
- Node dependency install
- frontend build
- Pint formatting check
- PHPStan static analysis
- Laravel migrations against sqlite
- Laravel test suite

## Registry usage

Current dev image repository:

- `registry.kwer.fr/kubequest/dev/sample-app-master`

The workflow publishes multi-architecture images for:

- `linux/amd64`
- `linux/arm64`

## Argo CD reconciliation summary

For the dev environment, the complete loop is:

1. PR merged into `dev`
2. GitHub Actions tests the app
3. GitHub Actions builds and pushes the image
4. GitHub Actions updates `values-dev.yaml`
5. GitHub Actions commits the version change to `dev`
6. Argo CD detects the Git change on `dev`
7. Argo CD syncs the chart to `sample-app-dev`
8. MySQL syncs first
9. migration job runs
10. app deployment rolls out

## Current prod state

The repository already contains a prod Argo CD application:

- `gitops/argocd/sample-app-prod.yaml`

It tracks `main` and deploys with `values-prod.yaml`.

However, the currently documented automated release workflow in this repository state is centered on the **dev branch pipeline** described above.

If prod automation is added later, it should follow the same GitOps principle:

- build immutable image
- update prod values in Git
- let Argo CD deploy from Git

## Operational notes

- Direct pushes to `dev` are assumed to be blocked by branch policy.
- The workflow is designed around **merged PRs into `dev`**.
- If bot pushes are protected on `dev`, GitHub Actions must be allowed to:
  - push commits to `dev`
  - push Git tags
- Sealed secrets must already be installed and working in the cluster.
- Argo CD must already be installed and syncing the `sample-app-dev` application.

## Quick summary

- `dev` branch is the active automated CI/CD branch
- unlabeled merged PR into `dev` = dev prerelease with SHA suffix
- labeled merged PR into `dev` = stable semantic release on dev + Git tag
- Argo CD deploys dev from `values-dev.yaml`
- prod app exists in Argo, but this document describes the currently implemented dev automation flow
