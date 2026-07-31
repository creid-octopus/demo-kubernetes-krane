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
#   scripts/deploy.sh <bindings-file> <context> <revision> [image-repo] [namespace]
#
# image-repo and namespace are both optional overrides — if omitted, each
# comes from the bindings file (IMAGE_REPO / NAMESPACE respectively).
# Passing either explicitly here wins over the bindings file. This is the
# pattern for any bindings-file value that also needs to be a live
# Octopus variable: keep a sane default in the bindings file for local/
# kind runs, and let Octopus pass the real value as an explicit arg when
# it wants to override it (e.g. Kubernetes.TargetNamespace, prompted at
# deploy time for Production — see the deployment process). Without an
# explicit override arg, a deploy-time Octopus variable change would only
# affect steps that reference the variable directly (like "create
# namespace if not exists"), not this script, since it only ever reads
# whatever's in the bindings file.
#
# Example:
#   scripts/deploy.sh k8s/bindings/development.env kind-demo-krane 1.0.7
set -euo pipefail

# Set script usage args and defaults

USAGE="usage: deploy.sh <bindings-file> <context> <revision> [image-repo] [namespace]"
BINDINGS_FILE="${1:?$USAGE}"
CONTEXT="${2:?$USAGE}"
REVISION="${3:?$USAGE}"
IMAGE_REPO_ARG="${4:-}"
NAMESPACE_ARG="${5:-}"

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

# Same precedence for both: explicit CLI arg > bindings file value >
# fallback (image-repo only — namespace has no safe fallback).
IMAGE_REPO="${IMAGE_REPO_ARG:-${IMAGE_REPO:-demo-kubernetes-krane}}"
NAMESPACE="${NAMESPACE_ARG:-${NAMESPACE:-}}"
export REVISION IMAGE_REPO

: "${NAMESPACE:?bindings file must set NAMESPACE, or pass one as the 5th arg}"
: "${REGION:?bindings file must set REGION}"

# In a Kubernetes Agent script pod there's no kubeconfig file on disk —
# plain `kubectl` still works there via client-go's in-cluster auto-
# discovery ($KUBERNETES_SERVICE_HOST/PORT + the mounted ServiceAccount
# token), but krane's Ruby kubeclient doesn't do that auto-discovery and
# requires an actual kubeconfig file: https://github.com/Shopify/krane/issues/729.
# If we're running in-cluster with no kubeconfig already set up, build
# one from the ServiceAccount's mounted credentials.
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

# 300s is short on purpose for a fast local/demo loop — bump to the
# 600-900s range for a real production workload.
#
# --no-prune: krane's default prune behavior deletes anything of an
# allowlisted kind in this namespace that isn't part of the current
# render, including objects it never created — like the Permissions
# Controller's own WorkloadServiceAccount, which lives in the same
# namespace it's granting access to. Granting `delete` just to let prune
# succeed would let this deploy identity delete its own RBAC grant.
krane render -f "$TEMPLATE_DIR" \
  | krane deploy "$NAMESPACE" "$CONTEXT" -f - --global-timeout 300s --no-prune
