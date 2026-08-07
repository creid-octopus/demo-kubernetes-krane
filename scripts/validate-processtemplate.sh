#!/usr/bin/env bash
#
# Generic form of scripts/validate-release.sh, intended to back an Octopus
# process template so the same gate can be reused across projects. Nothing
# about this repo is hardcoded — every input comes from an Octopus variable.
#
# What it does, unchanged from validate-release.sh: blocks the deployment
# unless, for the commit the release's image was built from,
#
#   1. every GitHub check run and commit status has completed successfully, and
#   2. the pull request that produced the commit is under the commit limit.
#
# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
# Read through `gate_var`, which prefixes each name with VAR_PREFIX (default
# `ReleaseValidation.`). Override VAR_PREFIX via `Gate.VariablePrefix` if the
# template's parameters are namespaced differently.
#
# Note: this step must be configured with **Syntax: Bash**. Octopus inline
# script steps default to PowerShell, which fails at parse time on the first
# shell function definition below — not near anything actually wrong.
#
# Required:
#   PackageReference     The package reference *name* as declared on THIS step
#                        (not the feed package ID). The unqualified
#                        Octopus.Action.Package[...] variables only resolve
#                        inside the action that owns the reference, so the
#                        reference must live on this step.
#
# Optional:
#   Repository           GitHub repo as `owner/name`. If unset, it's derived
#                        from the image's org.opencontainers.image.source
#                        label, which is why setting that label is worth it.
#   MaxCommits           Block at this many commits or more. Default 3.
#                        (A limit of N means "N-1 or fewer allowed".)
#   RequirePullRequest   `true` makes a commit with no associated PR a hard
#                        block. Default false — a direct push is a single
#                        commit, which is inside any limit by definition.
#   CheckTimeoutSeconds  How long to wait for pending checks. Default 600.
#   CheckPollSeconds     Interval between polls. Default 60. Each poll costs 2
#                        unauthenticated GitHub requests against a ~60/hour
#                        per-IP budget — and on Octopus Cloud that IP is a
#                        shared dynamic worker, so it isn't exclusively yours.
#   GitHubToken          Optional. If set, sent as a bearer token, raising the
#                        limit to 5,000/hour. Mark it sensitive. Left unset,
#                        the script works unauthenticated against public repos.
#   VersionShaPattern    Perl-regex used to recover a short SHA from the
#                        package version when the image carries no revision
#                        label. Default `sha-\K[0-9a-f]{7,40}`.
#
# ---------------------------------------------------------------------------
# Notes carried over from validate-release.sh
# ---------------------------------------------------------------------------
# - Octopus exposes `Octopus.Release.Package` / `Octopus.Release.Builds` (which
#   carry the commit list from build information) only to release notes
#   templates, never to deployment steps. Hence resolving the SHA from the
#   package and asking GitHub directly.
# - GitHub reports CI results through two independent mechanisms: check runs
#   (Checks API, used by GitHub Apps incl. GitHub Actions) and commit statuses
#   (the older Status API, used by e.g. Buildkite). Both are queried, because
#   querying one is silently blind to anything reporting through the other.
# - Decisions go through `write_highlight` so they land at the Highlight log
#   level on the task log itself rather than only in expanded step output.
#   Diagnostics stay on plain `echo`.
#   https://octopus.com/docs/deployments/custom-scripts/logging-messages-in-scripts#highlight-log-level

set -euo pipefail

# Allow for a variable prefix override, so the same template can be used in multiple
# contexts without having to rename all the variables.
# If Gate.VariablePrefix is unset, default to ReleaseValidation. so the template can be used in 
# a release validation step without having to rename all the variables.
VAR_PREFIX="$(get_octopusvariable "Gate.VariablePrefix" || true)"
VAR_PREFIX="${VAR_PREFIX:-ReleaseValidation.}"

# Reads "<prefix><name>", falling back to the second argument.
gate_var() {
  local value
  value="$(get_octopusvariable "${VAR_PREFIX}${1}" || true)"
  echo "${value:-${2:-}}"
}

# The package reference *name* is fixed by the template that declares it, so
# it defaults to "<prefix>PackageReference" — the name the template uses —
# rather than requiring a variable that just restates it. Override only if the
# template names its package reference something else.
PACKAGE_REF="$(gate_var PackageReference "${VAR_PREFIX}PackageReference")"
REPO="$(gate_var Repository)"
MAX_COMMITS="$(gate_var MaxCommits 3)"
REQUIRE_PR="$(gate_var RequirePullRequest false)"
POLL_TIMEOUT="$(gate_var CheckTimeoutSeconds 600)"
POLL_INTERVAL="$(gate_var CheckPollSeconds 60)"
GITHUB_TOKEN="$(gate_var GitHubToken)"
VERSION_SHA_PATTERN="$(gate_var VersionShaPattern 'sha-\K[0-9a-f]{7,40}')"

echo "--- Gate configuration"
echo "Variable prefix     : ${VAR_PREFIX}"
echo "Package reference   : '${PACKAGE_REF}'"
echo "Repository          : '${REPO}'${REPO:+}"
[ -z "$REPO" ] && echo "                      (unset — will derive from the image's source label)"
echo "Max commits         : ${MAX_COMMITS} (so $((MAX_COMMITS - 1)) or fewer allowed)"
echo "Require pull request: ${REQUIRE_PR}"
echo "Check timeout       : ${POLL_TIMEOUT}s, polling every ${POLL_INTERVAL}s"
echo "GitHub auth         : $( [ -n "$GITHUB_TOKEN" ] && echo "token supplied" || echo "unauthenticated (~60 req/hour per IP)" )"

if [ -z "$PACKAGE_REF" ]; then
  write_highlight "**Failing safe** — no package reference name resolved, so there's no package to inspect."
  exit 1
fi

# Catch a Repository value that was set but isn't a repository — most often an
# unresolved or mispasted Octopus variable. Without this the bad value lands in
# an API path and comes back as an opaque request failure.
if [ -n "$REPO" ]; then
  case "$REPO" in
    *'#{'*)
      write_highlight "**Failing safe** — \`${VAR_PREFIX}Repository\` contains an unresolved Octopus variable: \`${REPO}\`."
      echo "It should be a plain 'owner/name', e.g. creid-octopus/demo-kubernetes-krane."
      exit 1
      ;;
  esac
  # Tolerate a full GitHub URL here too, rather than only on the derived path.
  REPO=$(echo "$REPO" \
    | sed -E 's#^(https?://)?(www\.)?github\.com/##; s#\.git$##; s#/+$##')
  if ! echo "$REPO" | grep -qE '^[^/[:space:]]+/[^/[:space:]]+$'; then
    write_highlight "**Failing safe** — \`${VAR_PREFIX}Repository\` isn't an \`owner/name\` repository: \`${REPO}\`."
    echo "Expected something like creid-octopus/demo-kubernetes-krane, or leave it"
    echo "unset to derive it from the image's org.opencontainers.image.source label."
    exit 1
  fi
fi

if ! echo "$MAX_COMMITS" | grep -qE '^[0-9]+$' || [ "$MAX_COMMITS" -lt 1 ]; then
  write_highlight "**Failing safe** — \`${VAR_PREFIX}MaxCommits\` must be a positive integer, got \`${MAX_COMMITS}\`."
  exit 1
fi

for numeric in POLL_TIMEOUT POLL_INTERVAL; do
  if ! echo "${!numeric}" | grep -qE '^[0-9]+$' || [ "${!numeric}" -lt 1 ]; then
    write_highlight "**Failing safe** — \`${VAR_PREFIX}${numeric}\` must be a positive integer, got \`${!numeric}\`."
    exit 1
  fi
done

# Build the curl argument list once. Kept as an array so the token, when
# present, never has to be interpolated into a command string.
GH_CURL_ARGS=(-sf -H "Accept: application/vnd.github+json")
if [ -n "$GITHUB_TOKEN" ]; then
  GH_CURL_ARGS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

gh_get() {
  curl "${GH_CURL_ARGS[@]}" "$1"
}

echo "--- Resolving the commit SHA"

REVISION_LABEL="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].Image.Labels[org.opencontainers.image.revision]" || true)"
SOURCE_LABEL="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].Image.Labels[org.opencontainers.image.source]" || true)"
PACKAGE_VERSION="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].PackageVersion" || true)"
PACKAGE_ID="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].PackageId" || true)"
IMAGE="$(get_octopusvariable "Octopus.Action.Package[${PACKAGE_REF}].Image" || true)"

echo "Candidates:"
echo "  image                       : '${IMAGE}'"
echo "  revision label (preferred)  : '${REVISION_LABEL}'"
echo "  source label                : '${SOURCE_LABEL}'"
echo "  package version (fallback)  : '${PACKAGE_VERSION}'"

if [ -n "$REVISION_LABEL" ]; then
  SHA="$REVISION_LABEL"
  write_highlight "Commit **\`${SHA}\`** (from the image's revision label)"
elif [ -n "$PACKAGE_VERSION" ]; then
  SHA=$(echo "$PACKAGE_VERSION" | grep -oP "$VERSION_SHA_PATTERN" || true)
  if [ -z "$SHA" ]; then
    write_highlight "**Failing safe** — no revision label, and package version \`${PACKAGE_VERSION}\` doesn't match \`${VERSION_SHA_PATTERN}\`."
    echo "Set org.opencontainers.image.revision as an image label, or adjust"
    echo "${VAR_PREFIX}VersionShaPattern to match this project's versioning."
    echo "Raw version bytes:"
    printf '%s' "$PACKAGE_VERSION" | od -c | head -5
    exit 1
  fi
  echo "No revision label on this image — falling back to the version string."
  write_highlight "Commit **\`${SHA}\`** (parsed from version \`${PACKAGE_VERSION}\`)"
else
  write_highlight "**Failing safe** — neither a revision label nor a package version resolved for \`${PACKAGE_REF}\`."
  echo "Is the '${PACKAGE_REF}' package reference declared on THIS step? The"
  echo "unqualified Octopus.Action.Package[...] form only resolves inside the"
  echo "action that owns the reference."
  exit 1
fi

# Repository: explicit variable wins; otherwise derive from the source label,
# which for a GitHub-hosted project is the repo URL.
if [ -z "$REPO" ]; then
  if [ -n "$SOURCE_LABEL" ]; then
    REPO=$(echo "$SOURCE_LABEL" \
      | sed -E 's#^(https?://)?(www\.)?github\.com/##; s#\.git$##; s#/+$##')
    if echo "$REPO" | grep -qE '^[^/]+/[^/]+$'; then
      echo "Derived repository '${REPO}' from the image's source label."
    else
      write_highlight "**Failing safe** — couldn't derive an \`owner/name\` repository from source label \`${SOURCE_LABEL}\`."
      echo "Set ${VAR_PREFIX}Repository explicitly."
      exit 1
    fi
  else
    write_highlight "**Failing safe** — \`${VAR_PREFIX}Repository\` is unset and the image carries no org.opencontainers.image.source label to derive it from."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Checks are polled, not sampled once. The image push is typically what
# triggers the release, so a deployment often starts while the post-merge CI
# for that same commit is still running — judging instantly would block on
# "not completed yet", a timing artifact rather than a real failure.
#
#   any check FAILED     -> block immediately, waiting won't help
#   any check PENDING    -> wait and re-poll
#   nothing reported     -> wait too; results may not have posted yet
# ---------------------------------------------------------------------------

echo "--- Waiting for GitHub checks on ${SHA} in ${REPO}"
echo "Polling every ${POLL_INTERVAL}s, giving up after ${POLL_TIMEOUT}s."

DEADLINE=$(( $(date +%s) + POLL_TIMEOUT ))
ATTEMPT=0

while true; do
  ATTEMPT=$((ATTEMPT + 1))

  CHECK_RUNS=$(gh_get "https://api.github.com/repos/${REPO}/commits/${SHA}/check-runs") || {
    write_highlight "**Failing safe** — the GitHub check-runs request failed (rate limit, unknown commit, or private repo without a token)."
    exit 1
  }

  STATUSES=$(gh_get "https://api.github.com/repos/${REPO}/commits/${SHA}/statuses") || {
    write_highlight "**Failing safe** — the GitHub commit-statuses request failed (rate limit, unknown commit, or private repo without a token)."
    exit 1
  }

  # The statuses endpoint returns full history, so a context that failed and
  # was later re-run green appears twice. Reduce to the newest entry per
  # context before judging, otherwise a superseded failure blocks forever.
  LATEST_STATUSES=$(echo "$STATUSES" | jq -c \
    '[group_by(.context)[] | sort_by(.created_at) | last]')

  CHECK_RUN_TOTAL=$(echo "$CHECK_RUNS" | jq -r '.check_runs | length')
  STATUS_TOTAL=$(echo "$LATEST_STATUSES" | jq -r 'length')
  TOTAL=$((CHECK_RUN_TOTAL + STATUS_TOTAL))

  PENDING=$(( $(echo "$CHECK_RUNS" | jq -r '[.check_runs[] | select(.status != "completed")] | length') \
            + $(echo "$LATEST_STATUSES" | jq -r '[.[] | select(.state == "pending")] | length') ))

  FAILED=$(( $(echo "$CHECK_RUNS" | jq -r '[.check_runs[] | select(.status == "completed" and .conclusion != "success")] | length') \
           + $(echo "$LATEST_STATUSES" | jq -r '[.[] | select(.state == "failure" or .state == "error")] | length') ))

  echo "[attempt ${ATTEMPT}] ${TOTAL} check(s): ${PENDING} pending, ${FAILED} failed"
  echo "$CHECK_RUNS" | jq -r '.check_runs[] | "  check run  \(.name): \(.status)/\(.conclusion // "-")"'
  echo "$LATEST_STATUSES" | jq -r '.[] | "  status     \(.context): \(.state)"'

  if [ "$FAILED" -gt 0 ]; then
    write_highlight "**Blocking deployment** — ${FAILED} of ${TOTAL} GitHub check(s) failed for \`${SHA}\`."
    echo "$CHECK_RUNS" | jq -r \
      '.check_runs[] | select(.status == "completed" and .conclusion != "success")
       | "  check run  \(.name): \(.conclusion)  \(.html_url)"'
    echo "$LATEST_STATUSES" | jq -r \
      '.[] | select(.state == "failure" or .state == "error")
       | "  status     \(.context): \(.state)  \(.target_url // "-")"'
    exit 1
  fi

  if [ "$TOTAL" -gt 0 ] && [ "$PENDING" -eq 0 ]; then
    break
  fi

  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    if [ "$TOTAL" -eq 0 ]; then
      write_highlight "**Failing safe** — no check runs *or* commit statuses appeared for \`${SHA}\` within ${POLL_TIMEOUT}s."
      echo "Either CI never posted results for this commit, or the requests were"
      echo "throttled — indistinguishable without an authenticated call."
    else
      write_highlight "**Failing safe** — ${PENDING} of ${TOTAL} GitHub check(s) for \`${SHA}\` were still pending after ${POLL_TIMEOUT}s."
      echo "$CHECK_RUNS" | jq -r \
        '.check_runs[] | select(.status != "completed")
         | "  check run  \(.name): \(.status)  \(.html_url)"'
      echo "$LATEST_STATUSES" | jq -r \
        '.[] | select(.state == "pending")
         | "  status     \(.context): pending  \(.target_url // "-")"'
    fi
    exit 1
  fi

  if [ "$TOTAL" -eq 0 ]; then
    echo "Nothing reported yet — waiting ${POLL_INTERVAL}s."
  else
    echo "Waiting ${POLL_INTERVAL}s for ${PENDING} pending check(s)."
  fi
  sleep "$POLL_INTERVAL"
done

write_highlight "All ${TOTAL} GitHub check(s) passed — ${CHECK_RUN_TOTAL} check run(s), ${STATUS_TOTAL} commit status(es)."

echo "--- Resolving the pull request behind ${SHA}"

PR_JSON=$(gh_get "https://api.github.com/repos/${REPO}/commits/${SHA}/pulls") || {
  write_highlight "**Failing safe** — the GitHub commit-pulls request failed."
  exit 1
}

PR_NUMBER=$(echo "$PR_JSON" | jq -r '.[0].number // empty')

if [ -z "$PR_NUMBER" ]; then
  # No associated PR — a direct push to the branch. It can't be an oversized
  # squashed changeset: it's one commit, inside any limit by definition.
  if [ "$REQUIRE_PR" = "true" ]; then
    write_highlight "**Blocking deployment** — no pull request is associated with \`${SHA}\`, and \`${VAR_PREFIX}RequirePullRequest\` is set."
    echo "https://github.com/${REPO}/commit/${SHA}"
    exit 1
  fi

  COMMIT_COUNT=1
  CHANGESET_DESC="a direct push (no pull request)"
  write_highlight "Commit \`${SHA}\` was pushed directly to the branch, with no pull request — counting it as a 1-commit changeset."
  echo "Set ${VAR_PREFIX}RequirePullRequest to 'true' to block this instead."
  echo "https://github.com/${REPO}/commit/${SHA}"
else
  PR_URL="https://github.com/${REPO}/pull/${PR_NUMBER}"

  # Read the commit count off the PR rather than diffing the merge commit's
  # parents: under squash merges the commit on the target branch is always
  # exactly one, however large the PR was. The pre-squash count is the number
  # that actually describes the changeset.
  COMMIT_COUNT=$(gh_get "https://api.github.com/repos/${REPO}/pulls/${PR_NUMBER}" | jq -r '.commits // empty')

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

# ---------------------------------------------------------------------------
# Output variables
# ---------------------------------------------------------------------------
# Published so later steps consume the package details this step resolved,
# rather than re-deriving them from the package reference themselves. The point
# is a single source of truth: whatever package selection this step validated
# is exactly what downstream steps deploy, and they can't drift apart.
#
# Read them as:
#   #{Octopus.Action[<this action name>].Output.PackageId}
#   #{Octopus.Action[<this action name>].Output.PackageVersion}
#   #{Octopus.Action[<this action name>].Output.Image}
#   #{Octopus.Action[<this action name>].Output.CommitSha}
#   #{Octopus.Action[<this action name>].Output.CommitCount}
#   #{Octopus.Action[<this action name>].Output.PullRequestNumber}   (may be empty)
#
# Note this doesn't remove the dependency on the action's name — an output
# variable is still addressed by it. What it removes is the *second* coupling:
# downstream steps no longer need to know the package reference name too, and
# they get values that were validated rather than merely re-read.
echo "--- Publishing output variables"
set_octopusvariable "PackageId" "$PACKAGE_ID"
set_octopusvariable "PackageVersion" "$PACKAGE_VERSION"
set_octopusvariable "Image" "$IMAGE"
set_octopusvariable "CommitSha" "$SHA"
set_octopusvariable "CommitCount" "$COMMIT_COUNT"
set_octopusvariable "PullRequestNumber" "${PR_NUMBER:-}"
set_octopusvariable "Repository" "$REPO"

echo "  PackageId         = ${PACKAGE_ID}"
echo "  PackageVersion    = ${PACKAGE_VERSION}"
echo "  Image             = ${IMAGE}"
echo "  CommitSha         = ${SHA}"
echo "  CommitCount       = ${COMMIT_COUNT}"
echo "  PullRequestNumber = ${PR_NUMBER:-(none)}"
echo "  Repository        = ${REPO}"

# A downstream step that gets an empty PackageId will fail in a confusing way,
# so surface the problem here instead.
if [ -z "$PACKAGE_ID" ] || [ -z "$PACKAGE_VERSION" ]; then
  write_highlight "**Warning** — PackageId or PackageVersion resolved empty; downstream steps reading these outputs will get blanks."
fi
