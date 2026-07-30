#!/usr/bin/env bash
# Multi-region fan-out — stands in for "the same krane commands run for
# each region in parallel, fanned out with GNU parallel," a common pattern
# for teams running one app across several regional clusters. One
# "production deploy" here means: deploy this REVISION to every region in
# scripts/regions.conf, in parallel, and only succeed if all of them do.
#
# Usage:
#   scripts/fan-out.sh <revision> [regions-file] [image-repo]
#
# Example:
#   scripts/fan-out.sh 1.0.7
set -euo pipefail

REVISION="${1:?usage: fan-out.sh <revision> [regions-file] [image-repo]}"
REGIONS_FILE="${2:-scripts/regions.conf}"
IMAGE_REPO="${3:-demo-kubernetes-krane-app}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SH="$REPO_ROOT/scripts/deploy.sh"

if ! command -v parallel >/dev/null 2>&1; then
  echo "GNU parallel not found — falling back to sequential deploys." >&2
  echo "(brew install parallel to match the intended fan-out behavior)" >&2
  PARALLEL=0
else
  PARALLEL=1
fi

mapfile -t LINES < <(grep -vE '^\s*(#|$)' "$REGIONS_FILE")

if [[ "$PARALLEL" == "1" ]]; then
  printf '%s\n' "${LINES[@]}" | parallel --colsep ':' --line-buffer \
    "$DEPLOY_SH" '{3}' '{2}' "$REVISION" "$IMAGE_REPO"
else
  for line in "${LINES[@]}"; do
    IFS=':' read -r region context bindings <<< "$line"
    echo "── region: $region ──"
    "$DEPLOY_SH" "$bindings" "$context" "$REVISION" "$IMAGE_REPO"
  done
fi

echo "✓ fan-out deploy of ${IMAGE_REPO}:${REVISION} complete across: $(printf '%s\n' "${LINES[@]}" | cut -d: -f1 | paste -sd, -)"
