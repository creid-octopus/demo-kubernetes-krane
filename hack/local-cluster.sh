#!/usr/bin/env bash
# Stands up the local stand-in for "N EKS/AKS clusters pulling from one
# shared registry": one kind cluster + one local registry container, with
# a namespace per region (namespace creation is a separate step from
# krane deploy — see scripts/deploy.sh comments — matching the common
# pattern where namespaces are provisioned ahead of time, not by krane
# itself).
#
# Usage:
#   hack/local-cluster.sh up      # create cluster + registry + namespaces
#   hack/local-cluster.sh down    # tear everything down
set -euo pipefail

CLUSTER_NAME="demo-krane"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5001"
NAMESPACES=(app-development app-us app-eu)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

up() {
  if ! command -v kind >/dev/null 2>&1; then
    echo "kind not found — brew install kind" >&2
    exit 1
  fi

  # Local registry — same role as a single shared ECR/GHCR repo: one
  # place every "region" (namespace, here) pulls the same image from.
  if [[ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]]; then
    docker run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      --name "$REGISTRY_NAME" registry:2
  fi

  kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/hack/kind-config.yaml"

  docker network connect kind "$REGISTRY_NAME" 2>/dev/null || true

  for ns in "${NAMESPACES[@]}"; do
    kubectl --context "$KUBE_CONTEXT" create namespace "$ns" \
      --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
  done

  echo "✓ cluster '${KUBE_CONTEXT}' ready. Local registry at localhost:${REGISTRY_PORT}."
  echo "  Namespaces: ${NAMESPACES[*]}"
}

down() {
  kind delete cluster --name "$CLUSTER_NAME" || true
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
  echo "✓ torn down"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 {up|down}" >&2; exit 1 ;;
esac
