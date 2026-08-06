# demo-kubernetes-krane

A minified, runnable stand-in for a Krane-based Kubernetes deploy flow
(Shipit → Buildkite → Krane → EKS, per-region namespaces). Built to iterate
on locally before wiring up a real Octopus Deploy project.

See **[ARCHITECTURE.md](./ARCHITECTURE.md)** for what's modeled, what's
stubbed, and why.

## Prerequisites

- Docker
- [kind](https://kind.sigs.k8s.io/)
- kubectl
- Ruby + [Bundler](https://bundler.io/) (for `krane`)
- Optional: [GNU parallel](https://www.gnu.org/software/parallel/) — `fan-out.sh` falls back to sequential without it

```
bundle install   # installs krane per the Gemfile
```

## Quickstart

```
make cluster-up          # kind cluster + local registry + namespaces
make deploy-dev           # build, load, render+deploy to app-development
make logs                 # tail the running pods
```

Bump the version and redeploy to see a rolling update:

```
make deploy-dev REVISION=1.0.1
```

Deploy to a single "region" (namespace) directly, or fan out to all of them:

```
make deploy-us REVISION=1.0.1
make fan-out REVISION=1.0.1
```

Tear down:

```
make cluster-down
```

## Layout

```
app/                          minimal web + worker app, one Dockerfile, two targets
k8s/templates/                 krane .yml.erb templates (shared across envs/regions)
k8s/bindings/                  per-env/region .env files sourced before krane render
k8s/octopus-permissions-controller/
                                WorkloadServiceAccount / ClusterWorkloadServiceAccount
                                RBAC scoping for the real AKS clusters
scripts/validate-release.sh      Octopus deployment gate — GitHub checks + changeset size
scripts/deploy.sh               the "Shipit shells out to this" script
scripts/fan-out.sh              multi-region parallel deploy
scripts/regions.conf            region → context → bindings-file map
hack/local-cluster.sh           kind cluster + local registry + namespace setup
hack/kind-config.yaml           kind cluster config used by local-cluster.sh
tooling/Dockerfile               Kubernetes Agent script-pod tooling image (krane, kubectl, az)
.github/workflows/              ci.yml (build + krane smoke-deploy), build-toolbox.yml
                                (push tooling image to GHCR, manual dispatch), publish.yml
                                (build, publish, and deploy via Octopus — OIDC-authenticated)
.buildkite/pipeline.yml          Buildkite equivalent of publish.yml, also OIDC-authenticated
OIDC.md                          shared OIDC/Octopus design notes for both CI pipelines
command-reference.md            Helm commands for cert-manager + agent tooling-image overrides
Gemfile / Gemfile.lock          pins krane (installed via `bundle install`)
```
