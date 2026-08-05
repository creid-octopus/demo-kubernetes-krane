# Architecture notes

This repo is a minified, runnable stand-in for a Shipit → Buildkite → Krane
→ Kubernetes deploy flow, rebuilt on Octopus Deploy. It's small enough to
run end-to-end locally on `kind`, but structured so every piece maps
cleanly onto a real setup: per-env/region namespaces, multiple Deployments
per app (web/worker) rendered from shared templates, and a real Kubernetes
RBAC story via the Octopus Permissions Controller.

## What's modeled, and why a subset of resources

A representative flow renders: **ConfigMap, Deployment (web), Deployment
(worker), Service, PodDisruptionBudget** — one image, multiple processes,
multiple resource kinds converging together. That's enough to demonstrate
Krane rendering and applying a non-trivial set from one template directory
without pulling in cloud-specific resources (Ingress, VPC-CNI security
policies, etc.) that are either inert or error-prone on a local cluster.
Adding those back in later is just more `.yml.erb` templates in
`k8s/templates/` — the render/deploy mechanics don't change.

Out of scope for this demo: feature flags (app-level concern), Slack
notifications (a simple later Octopus step), canary deploys, and a
killswitch/config-patch mechanism (a good Runbook candidate for a fork to
add).

## Regions and environments

Locally, "regions" are namespaces on a single kind cluster (`app-us`,
`app-eu`) fanned out in parallel via `scripts/fan-out.sh` +
`scripts/regions.conf` (region → context → bindings-file). Every script
takes namespace and context as separate parameters for exactly this
reason — swapping `regions.conf` to point at real cluster contexts doesn't
require touching `deploy.sh` or the templates.

Against real infrastructure, this repo maps environments (not regions) to
clusters: `aks-nonprod` hosts `Development`/`Test` (as `app-dev`/`app-test`
namespaces), `aks-production` hosts `Production` (as `app-production`).
Modeling multiple *regions* as Octopus **Tenants** against a shared
Production environment is a natural next step for a fork that needs true
multi-region fan-out — this repo doesn't need it with only two clusters.

## CI/CD

- **`ci.yml`** — builds the image (dry run) and additionally spins up an
  ephemeral kind cluster in the runner, then runs `krane render | krane
  deploy` against a scratch namespace as a smoke test. This catches
  "does this app's manifests actually converge" at CI time rather than
  first finding out at deploy time.
- **`build-toolbox.yml`** — builds and pushes the Kubernetes Agent's
  script-pod tooling image (`tooling/Dockerfile`). Manual dispatch only —
  this image changes rarely, unlike the app image.
- **`publish.yml`** — real: builds and pushes the app image to GHCR,
  pushes build information, creates a release, and deploys to Development,
  authenticated to Octopus via OIDC (no API key).

A Buildkite pipeline (`.buildkite/pipeline.yml`) runs the equivalent flow
in parallel, also OIDC-authenticated, while both CI systems are being
evaluated side by side. See **[OIDC.md](./OIDC.md)** for the OIDC/Octopus
design details shared by both.

## Kubernetes Agent and RBAC

Both AKS clusters run the Octopus [Kubernetes
Agent](https://octopus.com/docs/kubernetes/targets/kubernetes-agent). The
deploy identity's permissions are scoped down to exactly what `krane
render | krane deploy` needs, using the Octopus Permissions Controller
(`k8s/octopus-permissions-controller/`) rather than a broad
cluster-admin-style service account — see the comments in
`nonprod-permissions.yml` and `production-permissions.yml` for the
specific RBAC rules and why each one exists. `command-reference.md` has
the cert-manager and agent-tooling-image Helm commands needed to stand
this up on a new cluster.

## Ideas for a fork

- Move `k8s/bindings/*.env` into Octopus project/tenant variables once
  Octopus is the source of truth for per-env config.
- Model true multi-region fan-out as a tenanted Production deployment
  instead of `scripts/fan-out.sh` + GNU `parallel`.
- Add a Runbook for the killswitch ConfigMap-patch use case.
- Add `ingress.yml.erb` / a VPC-CNI-style security policy template back
  in if your real cluster needs cloud-specific resources.
