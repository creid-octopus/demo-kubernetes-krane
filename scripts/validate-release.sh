#!/usr/bin/env bash
#
# Deployment gate, run as the "Validate Release" step in the Octopus
# `Kubernetes - Krane` deployment process, before anything touches the
# cluster. Blocks the deployment unless, for the commit this release's image
# was built from:
#
#   1. every GitHub check run has completed successfully, and
#   2. the pull request that produced the commit has fewer than 3 commits.
#
# Why this lives in a script step rather than reading Octopus's own build
# information: `Octopus.Release.Package` / `Octopus.Release.Builds` carry the
# commit list, but Octopus only exposes them to release notes templates, not
# to deployment steps. So the gate resolves the SHA from the package itself
# and asks GitHub directly.
#
# Resolving the SHA, in order of preference:
#   1. the image's `org.opencontainers.image.revision` label — the full
#      40-char SHA, travels inside the artifact, independent of any
#      versioning scheme. Only present on images built after the Dockerfile
#      gained its LABEL block.
#   2. the `sha-<7 hex>` suffix on the package version — the fallback for
#      older images. Depends on the channel's version rule holding.
#
# Both are read via the *unqualified* `Octopus.Action.Package[...]` form,
# which resolves only inside the action that declares the package reference —
# which is why the reference lives on this step. Step 3 reads it back off
# this one via the absolute `Octopus.Action[Validate Release].Package[...]`
# form, so there's a single package reference in the process.
#
# GitHub is called unauthenticated: the repo is public, and this keeps a
# static credential out of a process that's otherwise entirely OIDC. The
# tradeoff is a ~60 request/hour limit, and a throttled response is
# indistinguishable from "nothing found" — so every ambiguous case below
# fails closed rather than open.
#
# The decisions — resolved commit, check outcome, PR size, and every
# fail-safe reason — go through `write_highlight` so they surface at the
# Highlight log level on the Octopus task log itself, rather than only inside
# the expanded step output. Diagnostic detail stays on plain `echo`.
# https://octopus.com/docs/deployments/custom-scripts/logging-messages-in-scripts#highlight-log-level

set -euo pipefail

REPO="creid-octopus/demo-kubernetes-krane"
PACKAGE_REF="demo-kubernetes-krane"
MAX_COMMITS=3

# Not every commit on main arrives via a pull request — this repo is currently
# high-churn push-to-main. A direct push has no PR to measure, but it also
# can't *be* a large squashed changeset: it's one commit, which is inside the
# limit by definition. So the changeset check treats "no associated PR" as a
# single-commit changeset and warns, rather than blocking.
#
# The check-runs gate above it still applies either way — a direct push is
# only allowed through if its post-push CI is green.
#
# Set the Octopus project variable `Project.Gate.RequirePullRequest` to `true`
# to make a missing PR a hard block instead, once the workflow has moved to
# PRs and this allowance is no longer wanted.
REQUIRE_PR="$(get_octopusvariable "Project.Gate.RequirePullRequest" || true)"
REQUIRE_PR="${REQUIRE_PR:-false}"

echo "--- Resolving the commit SHA"

REVISION_LABEL="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].Image.Labels[org.opencontainers.image.revision]" || true)"
PACKAGE_VERSION="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].PackageVersion" || true)"
IMAGE="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].Image" || true)"

echo "Candidates:"
echo "  image                       : '${IMAGE}'"
echo "  revision label (preferred)  : '${REVISION_LABEL}'"
echo "  package version (fallback)  : '${PACKAGE_VERSION}'"

if [ -n "$REVISION_LABEL" ]; then
  SHA="$REVISION_LABEL"
  write_highlight "Commit **\`${SHA}\`** (from the image's revision label)"
elif [ -n "$PACKAGE_VERSION" ]; then
  SHA=$(echo "$PACKAGE_VERSION" | grep -oP 'sha-\K[0-9a-f]{7}' || true)
  if [ -z "$SHA" ]; then
    write_highlight "**Failing safe** — no revision label, and package version \`${PACKAGE_VERSION}\` has no \`sha-<7 hex>\` suffix."
    echo "Raw version bytes:"
    printf '%s' "$PACKAGE_VERSION" | od -c | head -5
    exit 1
  fi
  echo "No revision label — this image predates the Dockerfile LABEL block."
  write_highlight "Commit **\`${SHA}\`** (parsed from version \`${PACKAGE_VERSION}\`)"
else
  write_highlight "**Failing safe** — neither the revision label nor a package version resolved."
  echo "Is the '${PACKAGE_REF}' package reference declared on THIS step? The"
  echo "unqualified Octopus.Action.Package[...] form only resolves inside the"
  echo "action that owns the reference."
  exit 1
fi

# GitHub reports CI results through two independent mechanisms, and this repo
# has one CI system on each side of the split:
#
#   - Check runs (Checks API)      — GitHub Apps. GitHub Actions reports here.
#   - Commit statuses (Status API) — the older mechanism. Buildkite's GitHub
#                                    integration reports here.
#
# `/check-runs` returns only the first, `/statuses` only the second, so both
# have to be queried while both pipelines are live — checking one would look
# like it worked while being structurally blind to the other system's result.
#
# The single-call alternative is GraphQL's `statusCheckRollup`, which merges
# both, but GitHub's GraphQL API requires authentication even for public
# repos. Two unauthenticated REST calls keeps a static credential out of this
# step; swap to the rollup if the ~60 request/hour limit starts biting.

echo "--- Checking GitHub check runs for $SHA"

CHECK_RUNS=$(curl -sf -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/commits/${SHA}/check-runs") || {
  write_highlight "**Failing safe** — the GitHub check-runs request failed (rate limit, or unknown commit)."
  exit 1
}

CHECK_RUN_TOTAL=$(echo "$CHECK_RUNS" | jq -r '.check_runs | length')
if [ "$CHECK_RUN_TOTAL" -gt 0 ]; then
  echo "$CHECK_RUNS" | jq -r '.check_runs[] | "  \(.name): \(.status)/\(.conclusion // "-")"'
else
  echo "  (none)"
fi

CHECK_RUNS_NOT_GREEN=$(echo "$CHECK_RUNS" | jq -r \
  '[.check_runs[] | select(.status != "completed" or .conclusion != "success")] | length')

echo "--- Checking GitHub commit statuses for $SHA"

STATUSES=$(curl -sf -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/commits/${SHA}/statuses") || {
  write_highlight "**Failing safe** — the GitHub commit-statuses request failed (rate limit, or unknown commit)."
  exit 1
}

# The statuses endpoint returns full history, so a context that failed and was
# later re-run green appears twice. Reduce to the newest entry per context
# before judging, otherwise a superseded failure blocks forever.
LATEST_STATUSES=$(echo "$STATUSES" | jq -c \
  '[group_by(.context)[] | sort_by(.created_at) | last]')

STATUS_TOTAL=$(echo "$LATEST_STATUSES" | jq -r 'length')
if [ "$STATUS_TOTAL" -gt 0 ]; then
  echo "$LATEST_STATUSES" | jq -r '.[] | "  \(.context): \(.state)"'
else
  echo "  (none)"
fi

STATUSES_NOT_GREEN=$(echo "$LATEST_STATUSES" | jq -r \
  '[.[] | select(.state != "success")] | length')

TOTAL=$((CHECK_RUN_TOTAL + STATUS_TOTAL))
NOT_GREEN=$((CHECK_RUNS_NOT_GREEN + STATUSES_NOT_GREEN))

if [ "$TOTAL" -eq 0 ]; then
  write_highlight "**Failing safe** — no check runs *or* commit statuses reported for \`${SHA}\`."
  echo "Either CI hasn't posted results yet or the response was throttled —"
  echo "the two are indistinguishable on an unauthenticated call."
  exit 1
fi

if [ "$NOT_GREEN" -gt 0 ]; then
  write_highlight "**Blocking deployment** — ${NOT_GREEN} of ${TOTAL} GitHub check(s) are not green for \`${SHA}\`."
  echo "$CHECK_RUNS" | jq -r \
    '.check_runs[] | select(.status != "completed" or .conclusion != "success")
     | "  check run  \(.name): \(.status)/\(.conclusion // "-")  \(.html_url)"'
  echo "$LATEST_STATUSES" | jq -r \
    '.[] | select(.state != "success")
     | "  status     \(.context): \(.state)  \(.target_url // "-")"'
  exit 1
fi

write_highlight "All ${TOTAL} GitHub check(s) passed — ${CHECK_RUN_TOTAL} check run(s), ${STATUS_TOTAL} commit status(es)."

echo "--- Resolving the pull request behind $SHA"

PR_JSON=$(curl -sf -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/commits/${SHA}/pulls") || {
  write_highlight "**Failing safe** — the GitHub commit-pulls request failed."
  exit 1
}

PR_NUMBER=$(echo "$PR_JSON" | jq -r '.[0].number // empty')

if [ -z "$PR_NUMBER" ]; then
  # Direct push to main — no PR to measure. See REQUIRE_PR above.
  if [ "$REQUIRE_PR" = "true" ]; then
    write_highlight "**Blocking deployment** — no pull request is associated with \`${SHA}\`, and \`Project.Gate.RequirePullRequest\` is set."
    echo "https://github.com/${REPO}/commit/${SHA}"
    exit 1
  fi

  COMMIT_COUNT=1
  CHANGESET_DESC="a direct push (no pull request)"
  write_highlight "Commit \`${SHA}\` was pushed directly to the branch, with no pull request — counting it as a 1-commit changeset."
  echo "Set the project variable Project.Gate.RequirePullRequest to 'true' to block this instead."
  echo "https://github.com/${REPO}/commit/${SHA}"
else
  PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"

  # Read the commit count off the PR rather than diffing against the merge
  # commit's parents: these PRs are squash-merged, so the commit on main is
  # always exactly one commit no matter how large the PR was. The pre-squash
  # count is the number that actually describes the changeset.
  COMMIT_COUNT=$(curl -sf -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}" | jq -r '.commits // empty')

  if [ -z "$COMMIT_COUNT" ]; then
    write_highlight "**Failing safe** — couldn't read the commit count for [PR #${PR_NUMBER}](${PR_URL})."
    exit 1
  fi

  CHANGESET_DESC="[PR #${PR_NUMBER}](${PR_URL})"

  if [ "$COMMIT_COUNT" -ge "$MAX_COMMITS" ]; then
    write_highlight "**Blocking deployment** — ${CHANGESET_DESC} represents ${COMMIT_COUNT} commits; the limit is $((MAX_COMMITS - 1))."
    exit 1
  fi
  write_highlight "${CHANGESET_DESC} represents ${COMMIT_COUNT} commit(s), under the limit of ${MAX_COMMITS}."
fi

echo "--- Gate passed"
write_highlight "**Release validated** — commit \`${SHA}\`, ${TOTAL} check(s) green, ${COMMIT_COUNT} commit(s) from ${CHANGESET_DESC}."
