#!/usr/bin/env bash
# The script a Shipit-style deploy click would shell out to: it's handed
# a target (bindings file + kube context) and a REVISION (the commit SHA
# / image tag being deployed), and does the krane render + deploy. A
# rollback is just re-running this with the previous REVISION.
#
# Namespaces are NOT created here — krane requires the namespace to
# already exist (it has no --create-namespace flag). Namespace
# provisioning is a separate, earlier step. See hack/local-cluster.sh.
#
# Usage:
#   scripts/deploy.sh <bindings-file> <context> <revision> [image-repo]
#
# image-repo is optional — if omitted, it comes from IMAGE_REPO in the
# bindings file (each target declares its own correct image reference:
# local kind uses the bare name it was `kind load`-ed under, a real
# cluster needs the full registry path, e.g. ghcr.io/<owner>/<repo>).
# Passing it explicitly here still wins over the bindings file, for
# one-off overrides.
#
# Example:
#   scripts/deploy.sh k8s/bindings/development.env kind-demo-krane 1.0.7
set -euo pipefail

# Set script usage args and defaults

BINDINGS_FILE="${1:?usage: deploy.sh <bindings-file> <context> <revision> [image-repo]}"
CONTEXT="${2:?usage: deploy.sh <bindings-file> <context> <revision> [image-repo]}"
REVISION="${3:?usage: deploy.sh <bindings-file> <context> <revision> [image-repo]}"
IMAGE_REPO_ARG="${4:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/k8s/templates"

if [[ ! -f "$BINDINGS_FILE" ]]; then
  echo "bindings file not found: $BINDINGS_FILE" >&2
  exit 1
fi

if ! command -v krane >/dev/null 2>&1; then
  echo "krane not found — run: gem install krane (see Gemfile)" >&2
  exit 1
fi

# Load NAMESPACE, REGION, ENVIRONMENT, REPLICAS_*, etc. from the bindings
# file as real env vars — the ERB templates read them via ENV['X'], the
# same mechanism used for REVISION.
set -a
# shellcheck disable=SC1090
source "$BINDINGS_FILE"
set +a

# Precedence: explicit CLI arg > IMAGE_REPO from the bindings file >
# bare local-kind fallback.
IMAGE_REPO="${IMAGE_REPO_ARG:-${IMAGE_REPO:-demo-kubernetes-krane}}"
export REVISION IMAGE_REPO

: "${NAMESPACE:?bindings file must set NAMESPACE}"
: "${REGION:?bindings file must set REGION}"

# In a Kubernetes agent script pod there's no kubeconfig file on disk —
# plain `kubectl` still works there because client-go auto-discovers
# in-cluster config from $KUBERNETES_SERVICE_HOST/PORT + the mounted
# ServiceAccount token. krane's Ruby kubeclient doesn't do that same
# auto-discovery and still requires an actual kubeconfig file (confirmed
# not supported: https://github.com/Shopify/krane/issues/729). If we're
# running in-cluster and nothing has already set one up, build one from
# the ServiceAccount's own mounted credentials and use it.
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
if [[ -z "${KUBECONFIG:-}" && ! -f "${HOME}/.kube/config" && -f "${SA_DIR}/token" ]]; then
  echo "→ no kubeconfig found but a ServiceAccount token is mounted — building an in-cluster kubeconfig"
  export KUBECONFIG="${HOME}/.kube/config"
  mkdir -p "$(dirname "$KUBECONFIG")"
  kubectl config set-cluster in-cluster \
    --server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}" \
    --certificate-authority="${SA_DIR}/ca.crt" --embed-certs=true >/dev/null
  kubectl config set-credentials in-cluster --token="$(cat "${SA_DIR}/token")" >/dev/null
  kubectl config set-context in-cluster --cluster=in-cluster --user=in-cluster >/dev/null
  kubectl config use-context in-cluster >/dev/null
  # Whatever CONTEXT was passed in is meaningless here — the ServiceAccount
  # only has access to its own cluster, so use the context we just built.
  CONTEXT="in-cluster"
fi

echo "→ deploying ${IMAGE_REPO}:${REVISION} → namespace=${NAMESPACE} region=${REGION} context=${CONTEXT}"

# 300s here is short on purpose for a fast local/demo loop — a real
# production setup would likely want this in the 600-900s range. Bump
# this back up once you're pointed at real clusters with real load.
#
# --no-prune: krane's default prune behavior auto-discovers every
# resource kind/CRD on the cluster and deletes anything of an
# allowlisted kind in this namespace that isn't part of the current
# render — including objects it never created, like the Octopus
# Permissions Controller's WorkloadServiceAccount (Octopus's own docs
# say WSAs belong in the namespace you're deploying into). Granting
# `delete` on that just to let prune succeed would let this deploy
# identity delete its own RBAC grant, which is worse than not pruning.
krane render -f "$TEMPLATE_DIR" \
  | krane deploy "$NAMESPACE" "$CONTEXT" -f - --global-timeout 300s --no-prune
