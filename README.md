# kubequest

This repository contains:

- the application code (`services/`)
- GitHub Actions CI/CD workflows
- Helm charts for the GitOps-managed applications (`gitops/charts/`)
- Argo CD `Application` definitions (`gitops/argocd/`)
- sealed secrets consumed by Argo CD (`gitops/secrets/`)
- the raw Kubernetes/cluster-infrastructure manifests and the EC2 bootstrap script (`kubernetes/`)

This document describes the **current state implemented in the repository**: how a cluster node is bootstrapped, what runs on it, and how the two application CI/CD pipelines deploy through Argo CD.

## Repository structure

- `services/sample-app-master/`
  - Laravel/PHP application source code (the "sample app")
- `services/metrics-dashboard/`
  - static metrics/status dashboard served behind Caddy (`Caddyfile`, `Dockerfile`, `index.html`)
- `.github/workflows/`
  - `sample-app-master-ci.yml` - test, build, release and (on release) prod-promotion pipeline for the sample app
  - `sample-app-release-prep.yml` - validates that at most one `VERSION-*` label is present on PRs into `dev`
  - `metrics-dashboard-image.yml` - build/push pipeline for the metrics dashboard image
- `gitops/charts/sample-app/`
  - Helm chart for the sample app (Laravel app + MySQL + migration Job)
- `gitops/charts/metrics-dashboard/`
  - Helm chart for the metrics dashboard static site
- `gitops/argocd/`
  - Argo CD `Application` resources: `sample-app-dev.yaml`, `sample-app-prod.yaml`, `metrics-dashboard.yaml`, `pull-secrets.yaml`
- `gitops/secrets/`
  - sealed secrets consumed by the Argo CD-managed applications (registry pull secrets, app env secrets)
- `kubernetes/bootstrap-ec2.sh`
  - idempotent bootstrap script for an Amazon Linux 2023 EC2 host: installs `kubeadm`/`containerd`, initializes/joins the cluster, and (on the control-plane) installs the whole infrastructure stack below plus the GitOps root Applications
  - see [Cluster bootstrap](#cluster-bootstrap) below
- `kubernetes/infrastructure/`
  - Helm `values.yaml` + `ReferenceGrant`/`StorageClass`/`Middleware` manifests for every cluster-wide component installed by the bootstrap script (Traefik, Longhorn, Argo CD, Sealed Secrets, Grafana, kube-prometheus-stack, Loki, Alloy, Headlamp)
- `kubernetes/apps/`
  - raw manifests for workloads that are **not** managed through Argo CD/GitOps, applied directly by the bootstrap script: `registry` (self-hosted OCI registry), `whoami` (smoke-test app), and the `metrics` namespace + `HTTPRoute`/`IngressRoute` objects that expose the observability stack and the Argo CD/Traefik dashboards
- `kubernetes/traefik-ingress/`
  - Helm values for the Traefik release (Gateway API provider, NodePort 30080/30443)
- `kubernetes/nginx/`
  - the reverse-proxy `conf.d` tree (`sites-enabled/`, `snippets/`, `upstreams/`) that the bootstrap script symlinks into `/etc/nginx/conf.d` on the control-plane node; nginx terminates TLS (Certbot-managed certs) and forwards to Traefik's NodePort

## Cluster bootstrap

`kubernetes/bootstrap-ec2.sh` targets Amazon Linux 2023 and is meant to be run as root on every node:

```bash
sudo ROLE=control-plane bash kubernetes/bootstrap-ec2.sh
# on workers:
sudo ROLE=worker JOIN_COMMAND="$(cat /etc/kubernetes/join-command.sh)" bash kubernetes/bootstrap-ec2.sh
```

It is idempotent (safe to re-run) and, for both roles, does the OS/kubeadm-level prep: base packages, iSCSI (for Longhorn), sysctl/kernel modules, swap disabling, containerd, and the Kubernetes package repo.

On `ROLE=control-plane` it additionally (when `DEPLOY_STACK=true`, the default):

1. Runs `kubeadm init`, installs the flannel CNI, persists the join command.
2. Clones/updates this repository into `INSTALL_DIR` (`/opt/kubequest` by default).
3. Installs the Gateway API CRDs and Traefik (Gateway API provider, NodePort 30080/30443).
4. Installs Longhorn, then applies the extra `longhorn-2-replicas` `StorageClass` used by Grafana/Loki/kube-prometheus/the registry.
5. Installs Argo CD and the Sealed Secrets controller.
6. Creates the `metrics` and `registry` namespaces, then installs the observability stack into `metrics`: Grafana, kube-prometheus-stack, Loki (single-binary mode), and Alloy (log shipper feeding Loki). Installs Headlamp into `kube-system`.
7. Applies the cluster-wide `Gateway`, all `ReferenceGrant`s, the Traefik `Middleware`s (basic-auth, path-stripping) and their sealed secrets.
8. Applies the non-GitOps app manifests: the `metrics` `HTTPRoute`s (Argo CD/Grafana/Headlamp/kube-prometheus/Loki/Longhorn UIs), the Traefik dashboard/metrics `IngressRoute`s, `whoami`, and the self-hosted `registry` (auth secret + deployment + route).
9. Applies the four `gitops/argocd/*.yaml` `Application` manifests (`pull-secrets`, `sample-app-dev`, `sample-app-prod`, `metrics-dashboard`) - this is what actually turns the cluster into a GitOps-driven one; without this step Argo CD would be installed but tracking nothing. Set `BOOTSTRAP_GITOPS=false` to skip it.
10. If `INSTALL_NGINX=true` (default), symlinks every `*.conf` file under `kubernetes/nginx/conf.d/` (recursively one level, so `sites-enabled/`, `snippets/`, `upstreams/` are all picked up automatically) into `/etc/nginx/conf.d/` and reloads nginx.

All install steps use `helm upgrade --install` against the values files committed under `kubernetes/infrastructure/<component>/values.yaml`, so re-running the script re-applies the exact same desired state.

## Cluster infrastructure stack

Installed directly by `bootstrap-ec2.sh` via Helm (not through Argo CD - this is the platform layer Argo CD itself runs on top of):

| Component | Namespace | Purpose |
|---|---|---|
| Traefik | `traefik` | Gateway API implementation, edge entrypoint (NodePort 30080/30443) |
| Longhorn | `longhorn-system` | distributed block storage, default + `longhorn-2-replicas` `StorageClass`es |
| Argo CD | `argocd` | GitOps controller, exposed at `metrics.kwer.fr/argocd` |
| Sealed Secrets | `sealed-secrets` | decrypts the `SealedSecret`s committed in `kubernetes/infrastructure/secrets/` and `gitops/secrets/` |
| Grafana | `metrics` | dashboards, exposed at `metrics.kwer.fr/grafana` |
| kube-prometheus-stack | `metrics` | Prometheus (`prometheus-operated` service), exposed at `metrics.kwer.fr/prometheus` |
| Loki | `metrics` | log storage (single-binary mode), exposed at `metrics.kwer.fr/loki` |
| Alloy | `metrics` | DaemonSet log shipper, forwards pod logs to Loki |
| Headlamp | `kube-system` | Kubernetes web UI, exposed at `metrics.kwer.fr/headlamp` |
| registry | `registry` | self-hosted Docker registry at `registry.kwer.fr`, htpasswd-protected |
| nginx | host-level | TLS-terminating reverse proxy in front of Traefik's NodePort, per-domain confs under `kubernetes/nginx/conf.d/sites-enabled/` |

All `metrics.kwer.fr/*` routes except Grafana/Argo CD go through the `metrics-basic-auth` Traefik `Middleware`; `/longhorn` and `/loki` are additionally stripped of their path prefix via the `strip-first-segment` `Middleware`.

## GitOps / Argo CD applications

Four Argo CD `Application` resources live in `gitops/argocd/` and are applied by the bootstrap script:

- `pull-secrets`
  - tracks `gitops/secrets/` (recursive `directory` source) on `main`, sync-wave `-1`
  - distributes the `registry-pull-secret` (image pull) and `sample-app-env` sealed secrets into the `sample-app-dev`, `sample-app-prod` and `metrics` namespaces
- `sample-app-dev`
  - tracks the **`dev` branch**, renders `gitops/charts/sample-app` with `values.yaml` + `values-dev.yaml`
  - deploys to namespace `sample-app-dev`
- `sample-app-prod`
  - tracks the **`main` branch**, renders `gitops/charts/sample-app` with `values.yaml` + `values-prod.yaml`
  - deploys to namespace `sample-app-prod`
- `metrics-dashboard`
  - tracks the **`dev` branch**, renders `gitops/charts/metrics-dashboard` with `values.yaml` + `values-prod.yaml`
  - deploys to namespace `metrics`

All four use `syncPolicy.automated` (`prune`, `selfHeal`) with `CreateNamespace=true` (except `pull-secrets`, whose target namespaces are created by the other apps). Argo CD is Git-driven:

- when Git changes on the tracked branch
- Argo re-renders the Helm chart (or re-reads the secrets directory)
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

This is treated as a normal dev integration. Nothing is promoted to `main`/prod.

Flow:

1. CI reads the current core version from `values-dev.yaml`
2. CI computes a dev version:

   - `<core-version>-dev.<merge-sha-12>`

   Example:

   - `0.4.0-dev.a1b2c3d4e5f6`

3. CI runs tests
4. CI builds the multi-arch Docker image
5. CI pushes the image to:

   - `registry.kwer.fr/kubequest/dev/sample-app-master:<dev-version>`
   - `registry.kwer.fr/kubequest/dev/sample-app-master:sha-<merge-sha>`

6. CI updates `gitops/charts/sample-app/values-dev.yaml`:

   - `image.tag`
   - `migration.releaseId`

7. CI commits the updated `values-dev.yaml` back to `dev`
8. Argo CD sees the Git change on `dev`
9. Argo CD deploys the new version to `sample-app-dev`

### Case 2 - merged PR into `dev` with a `VERSION-*` label

This is treated as a **release cut that is promoted straight to prod**, not just a dev release.

Supported labels (looked up via `gh pr view --json labels`):

- `VERSION-MAJOR`
- `VERSION-MINOR`
- `VERSION-HOT`

Flow:

1. CI reads the previous stable Git tags matching `vX.Y.Z`
2. CI computes the next stable version:

   - `VERSION-MAJOR` → `+1.0.0`
   - `VERSION-MINOR` → `+0.1.0`
   - `VERSION-HOT` → `+0.0.1`

3. CI runs tests
4. CI builds the multi-arch Docker image
5. CI pushes the image to **both** registry repositories, tagged with the new version and the merge SHA:

   - `registry.kwer.fr/kubequest/dev/sample-app-master:<new-version>`
   - `registry.kwer.fr/kubequest/prod/sample-app-master:<new-version>`
   - `registry.kwer.fr/kubequest/dev/sample-app-master:sha-<merge-sha>`
   - `registry.kwer.fr/kubequest/prod/sample-app-master:sha-<merge-sha>`

6. CI creates and pushes the new Git tag (e.g. `v0.5.0`), skipping if it already exists
7. CI updates **both** `gitops/charts/sample-app/values-dev.yaml` and `values-prod.yaml`:

   - `image.tag = <new-version>`
   - `migration.releaseId = <new-version>`

8. CI commits both files back to `dev`
9. CI **merges `dev` into `main`** (`git merge --no-ff`) and pushes `main` directly - this is what promotes the release to prod
10. Argo CD sees the Git change on `dev` → deploys `sample-app-dev`
11. Argo CD sees the Git change on `main` → deploys `sample-app-prod`

So a labeled merge into `dev` is a one-shot release train: dev and prod end up on the exact same image/version, and `main` only ever moves via this automated merge (no manual PRs into `main` are expected).

## What the workflow tests

Before image build/push, CI runs:

- Composer validation
- PHP dependency install
- Node dependency install
- frontend build (`npm run production`)
- Pint formatting check
- PHPStan static analysis
- Laravel migrations against sqlite
- Laravel test suite

## Registry usage

Image repositories on the self-hosted registry:

- `registry.kwer.fr/kubequest/dev/sample-app-master` - every merge into `dev` (dev and release versions)
- `registry.kwer.fr/kubequest/prod/sample-app-master` - only release-labeled merges (mirrors the dev image, same tag)
- `registry.kwer.fr/kubequest/prod/metrics-dashboard` - built independently by `metrics-dashboard-image.yml` on every push to `dev` touching `services/metrics-dashboard/**`

All workflows publish multi-architecture images for:

- `linux/amd64`
- `linux/arm64`

## Argo CD reconciliation summary

For an **unlabeled** dev merge, the complete loop is:

1. PR merged into `dev`
2. GitHub Actions tests the app
3. GitHub Actions builds and pushes the dev image
4. GitHub Actions updates `values-dev.yaml`
5. GitHub Actions commits the version change to `dev`
6. Argo CD detects the Git change on `dev`
7. Argo CD syncs the chart to `sample-app-dev`
8. MySQL syncs first, migration job runs, app deployment rolls out

For a **release-labeled** dev merge, steps 1-8 above still happen, plus:

9. GitHub Actions also pushes the prod image and updates `values-prod.yaml`
10. GitHub Actions merges `dev` into `main` and pushes `main`
11. Argo CD detects the Git change on `main`
12. Argo CD syncs the chart to `sample-app-prod` (same wave-ordered MySQL → migration → deployment rollout)

## Current prod state

Prod deployment is automated: `gitops/argocd/sample-app-prod.yaml` tracks `main`, and `main` is only ever advanced by the CI-driven `dev`→`main` merge described above (Case 2). There is no separate manual prod release process and no expectation of direct PRs into `main`.

## Operational notes

- Direct pushes to `dev` are assumed to be blocked by branch policy.
- The workflow is designed around **merged PRs into `dev`**.
- GitHub Actions must be allowed to:
  - push commits to `dev`
  - push commits to `main` (release promotion)
  - push Git tags
- Sealed secrets must be sealed with the cluster's actual controller cert (`kubernetes/infrastructure/secrets/sealed-secrets-cert.pem` is the public cert used to seal new ones).
- Argo CD and the rest of the infrastructure stack are expected to already be installed via `kubernetes/bootstrap-ec2.sh` before any of the GitOps flows above can do anything.

## Quick summary

- `dev` branch is the active automated CI/CD branch
- unlabeled merged PR into `dev` = dev-only prerelease with SHA suffix
- labeled merged PR into `dev` = stable semantic release, pushed to **both** dev and prod image repos, and auto-promoted to `main`
- Argo CD deploys `sample-app-dev` from `dev`/`values-dev.yaml` and `sample-app-prod` from `main`/`values-prod.yaml`
- `kubernetes/bootstrap-ec2.sh` bootstraps the whole platform (Traefik, Longhorn, Argo CD, Sealed Secrets, Grafana/Loki/kube-prometheus-stack/Alloy/Headlamp, the self-hosted registry, nginx) and applies the four `gitops/argocd/*.yaml` Applications that turn the cluster into a GitOps target
